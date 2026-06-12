module ext::custom_allocators::arena;
import ext::collections::smart_slice;

// Aliases for public use.
alias Arena = ArenaAlloc{false};
alias ThreadArena = ArenaAlloc{true};

typedef ArenaMark = sz;

module ext::custom_allocators::arena <THREAD_SAFE>;
import std::math;
import std::io;
import std::atomic;
import std::thread @norecurse;

// Individual allocation structure: [header|payload|padding]

const DEFAULT_INIT_CAPACITY  @local = 4096;
const MIN_INIT_CAPACITY      @local = 512;
const HEADER_SIZE            @local = allocators::DEFAULT_SIZE_PREFIX;

struct ArenaAlloc (Allocator, Printable) @private
{
	char* memory;
	struct @if(!THREAD_SAFE)
	{
		sz cursor;
		sz capacity;
		sz mark_count;
	}
	struct @if(THREAD_SAFE)
	{
		Atomic{sz} cursor;
		Atomic{sz} capacity;
		Atomic{sz} mark_count;
	}
	Allocator backing_alloc;
	// Mutex mutex @if(THREAD_SAFE);
}

<*
 Initializes the arena.

 @require init_capacity >= MIN_INIT_CAPACITY : "Should be bigger than minimum"
*>
fn void ArenaAlloc.init(
	&self,
	Allocator backing_alloc = mem,
	sz init_capacity = DEFAULT_INIT_CAPACITY,
)
{
	self.memory = alloc::malloc(backing_alloc, init_capacity);
$if THREAD_SAFE:
	self.capacity.store(init_capacity);
	self.cursor.store(0);
	self.mark_count.store(0);
$else
	self.capacity = init_capacity;
	self.cursor = 0;
	self.mark_count = 0;
$endif
	self.backing_alloc = backing_alloc;
}

<*
 Acquire memory from the allocator, with the given alignment and initialization type.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require size > 0 : "The size must be 1 or more"
 @return ? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAlloc.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	sz aligned_size_with_header = mem::aligned_offset(alignment + HEADER_SIZE + size, mem::DEFAULT_MEM_ALIGNMENT);
	sz aligned_size = aligned_size_with_header - HEADER_SIZE;

$if THREAD_SAFE:
	sz curr_cursor = cursor(self);
	sz new_cursor @noinit;
	sz remain @noinit;
	
	do
	{
		if (remain_mem(self, curr_cursor) < aligned_size_with_header) return self.backing_alloc.acquire(size, init_type, alignment);
		new_cursor = curr_cursor + aligned_size_with_header;
	} while (!self.cursor.compare_exchange(&curr_cursor, new_cursor));

	char* start = (char*)&self.memory + new_cursor + HEADER_SIZE;
	char* ret = mem::aligned_pointer(start, alignment);
	sz* header = (sz*)(ret - HEADER_SIZE);
	*header = aligned_size;
	if (init_type == ZERO)
	{
		mem::clear(ret, aligned_size);
	}
	return ret;
$else
	char* start = (char*)&self.memory + self.cursor + HEADER_SIZE;
	char* ret = mem::aligned_pointer(start, alignment);
	sz* header = (sz*)(ret - HEADER_SIZE);
	*header = aligned_size;
	self.cursor += aligned_size_with_header;
	if (init_type == ZERO)
	{
		mem::clear(ret, aligned_size);
	}
	return ret;
$endif
}

<*
 Resize acquired memory from the allocator, with the given new size and alignment.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require ptr != null
 @require new_size > 0
 @return ? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? ArenaAlloc.resize(&self, void* ptr, sz new_size, sz alignment = 0) @dynamic
{
	sz aligned_new_size = mem::aligned_offset(new_size, mem::DEFAULT_MEM_ALIGNMENT);
	sz* old_size = (sz*)((char*)ptr - HEADER_SIZE);
	sz alloc_size_diff = aligned_new_size - *old_size;

$if THREAD_SAFE:
	sz curr_cursor = self.cursor.load();
	sz new_cursor @noinit;

	do
	OUTER: {
		bool last_alloc = is_last_alloc(self, curr_cursor, ptr, *old_size);
		if (last_alloc && alloc_size_diff > remain_mem(self, cursor))
		{
			// Extend allocation.
			new_cursor = curr_cursor + alloc_size_diff;
			if (self.cursor.compare_exchange(&curr_cursor, new_cursor))
			{
				*old_size = aligned_new_size;
				return ptr;
			}
			else
			{
				continue OUTER;
			}
		}
		else
		{
			// Do fresh allocation.
			void* ret = self.acquire(new_size, NO_ZERO, alignment)!;
			mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
			return ret;
		}
	} while (true);
$endif
	bool last_alloc = is_last_alloc(self, self.cursor, ptr, *old_size);
	if (last_alloc && alloc_size_diff > remain_mem(self, self.cursor))
	{
		// Extend allocation.
		self.cursor += alloc_size_diff;
		return ptr;
	}
	// Do fresh allocation.
	void* ret = self.acquire(new_size, NO_ZERO, alignment)!;
	mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
	return ret;
}

<*
 Release memory acquired using `acquire` or `resize`.
 It is not a good practice to free individual pointers from arena
 Consider using marks, @temp_scope, or resetting whole arena.

 @require ptr != null : "Empty pointers should never be released"
*>
fn void ArenaAlloc.release(&self, void* ptr, bool) @dynamic
{
$if THREAD_SAFE:
	sz* alloc_size = (sz*)(ptr - HEADER_SIZE);
	sz expected_cursor = cursor(self);
	sz old_cursor = expected_cursor;
	if (!is_last_alloc(self, expected_cursor, ptr, *alloc_size))
	{
		return;
	}
	sz new_cursor = old_cursor - (sz)(*alloc_size + HEADER_SIZE);
	if (self.cursor.compare_exchange(&expected_cursor, new_cursor)) return;
	self.cursor.store(math::min(expected_cursor, new_cursor));
$else
	sz* alloc_size = (sz*)(ptr - HEADER_SIZE);
	if (!is_last_alloc(self, self.cursor, ptr, *alloc_size))
	{
		return;
	}
	self.cursor -= (sz)(*alloc_size + HEADER_SIZE);
$endif
}

<*
 Create a 'mark' from which you can start doing temporary allocations,
 then easily reclaim them back with 'rewind_mark'
*>
fn ArenaMark ArenaAlloc.save_mark(&self)
{
	ArenaMark mark = cursor(self);
$if THREAD_SAFE:
	self.mark_count.add(1);
$else
	self.mark_count++;
$endif
	return mark;
}

<*
 Reclaim all memory used since a call to 'save_mark'
*>
fn void ArenaAlloc.rewind_mark(&self, ArenaMark mark)
{
$if THREAD_SAFE:
	self.cursor.store(mark);
	self.mark_count.sub(1);
$else
	self.cursor = mark;
	self.mark_count--;
$endif
}

<*
 Create a temporary allocation scope around provided body, all allocated memory will be freed at the end.
*>
macro ArenaAlloc.@temp_scope(&self; @body())
{
	ArenaMark mark = self.save_mark();
	defer self.rewind_mark(mark);
	@body();
}

<*
 Create a temporary allocation scope around provided body, all allocated memory will be freed at the end.
 Additionaly passes 'alloc' param which is Allocator interface.
*>
macro ArenaAlloc.@temp_scope_alloc(&self; @body(Allocator alloc))
{
	ArenaMark mark = self.save_mark();
	defer self.rewind_mark(mark);
	@body(self);
}

<*
 Reclaim all used memory, allowing for reuse.
*>
fn void ArenaAlloc.reset(&self)
{
	set_cursor(self, 0);
}

<*
 Free all the memory storage of arena and return it to backing allocator.

 @require self.regions != null : "Should be initialized"
*>
fn void ArenaAlloc.free(&self)
{
	if (self.memory)
	{
		set_cursor(self, 0);
		set_capacity(self, 0);
		alloc::free(self.backing_alloc, self.memory);
		self.memory = null;
	}
}

// <*
//  Implements 'Printable' interface.
// *>
// fn sz? ArenaAlloc.to_format(&self, Formatter* fmt) @dynamic
// {
// $if THREAD_SAFE:
// 	self.mutex.lock();
// 	defer self.mutex.unlock();
// $endif
// 	sz total = fmt.print("Arena allocator info: [cursor : capacity]")!;
// 	ArenaRegion* curr = self.regions;

// 	while (curr)
// 	{
// 		fmt.printf("\n\t[%s : %s], remain: %s", curr.cursor, curr.capacity, remain_mem(curr))!;
// 		curr = curr.next;
// 	}

// 	return total;
// }

// // Mimic std api without virtual function call overhead.

// macro ArenaAlloc.alloc_array(&self, $Type, sz count) => _alloc_array{$Type, THREAD_SAFE}(self, count);

// fn AllocElemType[] _alloc_array(ArenaAlloc{THREAD_SAFE}* self, sz count) <AllocElemType, THREAD_SAFE>
// {
// 	sz size = AllocElemType::size * count;
// 	return ((AllocElemType*)self.acquire(size, NO_ZERO)!!)[:count];
// }

// macro ArenaAlloc.new_array(&self, $Type, sz count) => _new_array{$Type, THREAD_SAFE}(self, count);

// fn AllocElemType[] _new_array(ArenaAlloc{THREAD_SAFE}* self, sz count) <AllocElemType, THREAD_SAFE>
// {
// 	sz size = AllocElemType::size * count;
// 	return ((AllocElemType*)self.acquire(size, ZERO)!!)[:count];
// }

// <*
//  @require @kindof(old_slice) == SLICE : "Must be slice"
// *>
// macro ArenaAlloc.realloc_array(&self, old_slice, sz new_count) => _realloc_array{$Typeof(old_slice[0]), THREAD_SAFE}(self, old_slice, new_count);

// fn AllocElemType[] _realloc_array(ArenaAlloc{THREAD_SAFE}* self, AllocElemType[] old_slice, sz new_count) <AllocElemType, THREAD_SAFE>
// {
// 	sz new_size = AllocElemType::size * new_count;
// 	return ((AllocElemType*)self.resize(old_slice.ptr, new_size)!!)[:new_count];
// }

// macro ArenaAlloc.alloc_smart_array(&self, $Type, sz count) => _alloc_smart_array{$Type, THREAD_SAFE}(self, count);

// fn SmartSlice{AllocElemType} _alloc_smart_array(ArenaAlloc{THREAD_SAFE}* self, sz count) <AllocElemType, THREAD_SAFE>
// {
// 	SmartSlice{AllocElemType} res @noinit;
// 	sz size = AllocElemType::size * count;
// 	res.items = ((AllocElemType*)self.acquire(size, NO_ZERO)!!)[:count];
// 	res.size = 0;
// 	return res;
// }

// macro ArenaAlloc.new_smart_array(&self, $Type, sz count) => _new_smart_array{$Type, THREAD_SAFE}(self, count);

// fn SmartSlice{AllocElemType} _new_smart_array(ArenaAlloc{THREAD_SAFE}* self, sz count) <AllocElemType, THREAD_SAFE>
// {
// 	SmartSlice{AllocElemType} res @noinit;
// 	sz size = AllocElemType::size * count;
// 	res.items = ((AllocElemType*)self.acquire(size, ZERO)!!)[:count];
// 	res.size = 0;
// 	return res;
// }

// macro ArenaAlloc.realloc_smart_array(&self, old_arr, sz new_count) => _realloc_smart_array{$Typeof(old_arr.items[0]), THREAD_SAFE}(self, old_arr, new_count);

// fn SmartSlice{AllocElemType} _realloc_smart_array(ArenaAlloc{THREAD_SAFE}* self, SmartSlice{AllocElemType} old_arr, sz new_count) <AllocElemType, THREAD_SAFE>
// {
// 	SmartSlice{AllocElemType} res @noinit;
// 	sz new_size = AllocElemType::size * new_count;
// 	res.items = ((AllocElemType*)self.resize(old_arr.items.ptr, new_size)!!)[:new_count];
// 	res.size = new_count;
// 	return res;
// }

// fn void* ArenaAlloc.malloc(&self, sz size)
// {
// 	return self.acquire(size, NO_ZERO)!!;
// }

// fn void* ArenaAlloc.calloc(&self, sz size)
// {
// 	return self.acquire(size, ZERO)!!;
// }

// fn void* ArenaAlloc.realloc(&self, void* ptr, sz new_size)
// {
// 	return self.resize(ptr, new_size)!!;
// }

// // Only for compatibility reasons and external interfacing with C.
// fn void* ArenaAlloc.c_realloc(&self, void* ptr, sz new_size)
// {
// 	if (!ptr)
// 	{
// 		return self.malloc(new_size);
// 	}
// 	else if (new_size == 0)
// 	{
// 		// We don't want free on arenas, just use temp_scope.
// 		return null;
// 	}
// 	return _realloc(self, ptr, new_size)!!;
// }

// macro ArenaAlloc.alloc(&self, $Type) => _alloc{$Type, THREAD_SAFE}(self);

// fn AllocType* _alloc(ArenaAlloc{THREAD_SAFE}* self) <AllocType, THREAD_SAFE> @local
// {
// 	return self.acquire(AllocType::size, NO_ZERO)!!;
// }

// <*
//  @require @kindof(val) != POINTER : "Should pass by value"
// *>
// macro ArenaAlloc.clone(&self, val) => _clone{$Typeof(val), THREAD_SAFE}(self, val);

// fn CloneType* _clone(ArenaAlloc{THREAD_SAFE}* self, CloneType val) <CloneType, THREAD_SAFE> @local
// {
// 	CloneType* res = self.alloc(CloneType);
// 	*res = val;
// 	return res;
// }

// // ------ Private API ------

<*
 Tell if provided pointer is owned by this allocator memory.
*>
fn bool owns_ptr(ArenaAlloc* self, void* ptr) @inline @local
{
	return ((char*)ptr >= (char*)&self.memory) && ((char*)ptr < ((char*)&self.memory + capacity(self)));
}

<*
 Tell how much free memory arena region has.
*>
fn sz remain_mem(ArenaAlloc* self, sz cursor) @inline @local
{
$if THREAD_SAFE:
	return self.capacity.load() - cursor;
$else
	return self.capacity - self.cursor;
$endif
}

macro sz cursor(ArenaAlloc* self) @local
{
$if THREAD_SAFE:
	return self.cursor.load();
$else
	return self.cursor;
$endif
}

macro void set_cursor(ArenaAlloc* self, sz val) @local
{
$if THREAD_SAFE:
	self.cursor.store(val);
$else
	self.cursor = val;
$endif
}

macro capacity(ArenaAlloc* self) @local
{
$if THREAD_SAFE:
	return self.capacity.load();
$else
	return self.capacity;
$endif
}

macro void set_capacity(ArenaAlloc* self, sz val) @local
{
$if THREAD_SAFE:
	self.capacity.store(val);
$else
	self.capacity = val;
$endif
}

macro mark_count(ArenaAlloc* self) @local
{
$if THREAD_SAFE:
	return self.mark_count.load();
$else
	return self.mark_count;
$endif
}

<*
 Tell if provided allocation is last in the region.
*>
fn bool is_last_alloc(ArenaAlloc* self, sz cursor, void* ptr, sz alloc_size) @inline @local
{
	sz alloc_cursor = ((char*)ptr + alloc_size) - (char*)&self.memory;
	return alloc_cursor == cursor;
}
