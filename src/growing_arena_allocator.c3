module ext::allocators::growing_arena;

// Aliases for public use.
alias GrowingArena = GrowingArenaImpl{false};
alias ThreadGrowingArena = GrowingArenaImpl{true};

module ext::allocators::growing_arena <THREAD_SAFE>;
import std::math;
import std::io;
import std::atomic;
import ext::collections::smart_slice;
import std::thread @norecurse;

// Individual allocation structure: [header|payload|padding]

const DEFAULT_REGION_CAPACITY @private = 4096;
const MIN_REGION_CAPACITY @private     = 512;
const DEFAULT_REGION_COUNT @private    = 2;
const HEADER_SIZE @private             = allocators::DEFAULT_SIZE_PREFIX;

struct GrowingArenaImpl (Allocator, Printable) @private
{
	sz mark_count @if(!THREAD_SAFE);
	Atomic{sz} mark_count @if(THREAD_SAFE);
	sz min_region_capacity;
	GrowingArenaRegion* last_alloc_region;
	Allocator backing_alloc;
	GrowingArenaRegion root;
}

struct GrowingArenaRegion @private
{
	struct @if(!THREAD_SAFE)
	{
		sz capacity;
		sz cursor;
	}
	struct @if(THREAD_SAFE)
	{
		Atomic{sz} capacity;
		Atomic{sz} cursor;
	}
	GrowingArenaRegion* next;
	GrowingArenaRegion* prev;
	sz idx;
	char[*] memory;
}

struct GrowingArenaMark
{
	GrowingArenaRegion* region;
	sz cursor;
}

<*
 Initializes the arena.

 @require min_region_capacity >= MIN_REGION_CAPACITY : "Shouldn't be less than this"
 @require first_region_capacity >= MIN_REGION_CAPACITY : "Shouldn't be less than this"
 @require first_region_capacity >= min_region_capacity : "Shouldn't be less than this"
*>
fn GrowingArenaImpl* create(
	Allocator backing_alloc,
	sz first_region_capacity = DEFAULT_REGION_CAPACITY,
	sz min_region_capacity = DEFAULT_REGION_CAPACITY,
)
{
	GrowingArenaImpl* self = alloc::alloc_with_padding(backing_alloc, GrowingArenaImpl, first_region_capacity)!!;
	set_cursor(&self.root, 0);
	set_capacity(&self.root, first_region_capacity);
	self.root.prev = null;
	self.root.next = null;
	self.root.idx = 0;
	self.min_region_capacity = min_region_capacity;
	self.last_alloc_region = &self.root;
	self.backing_alloc = backing_alloc;
	return self;
}

<*
 Acquire memory from the allocator, with the given alignment and initialization type.

 @require !alignment || math::is_power_of_2(alignment)
 @require alignment <= mem::MAX_MEMORY_ALIGNMENT : `alignment too big`
 @require size > 0 : "The size must be 1 or more"
 @return ? mem::INVALID_ALLOC_SIZE, mem::OUT_OF_MEMORY
*>
fn void*? GrowingArenaImpl.acquire(&self, sz size, AllocInitType init_type, sz alignment = 0) @dynamic
{
	alignment = allocators::alignment_for_allocation(alignment);
	sz aligned_size_with_header  = mem::aligned_offset(alignment + HEADER_SIZE + size, mem::DEFAULT_MEM_ALIGNMENT);
	sz aligned_size              = aligned_size_with_header - HEADER_SIZE;
	GrowingArenaRegion* last_reg = self.last_alloc_region;

	$if THREAD_SAFE:
		GrowingArenaRegion* curr_reg       = mark_count(self) > 0 ? last_reg : &self.root;
		GrowingArenaRegion* prev_reg       = null;
		GrowingArenaRegion* sufficient_reg = null;
		sz remain @noinit;
		sz curr_cursor @noinit;
		sz next_cursor @noinit;
		sz old_cursor @noinit;

		while OUTER: (curr_reg)
		{
			curr_cursor = cursor(curr_reg);
			do
			{
				old_cursor = curr_cursor;
				remain = remain_mem(curr_reg, curr_cursor);
				if (aligned_size_with_header > remain) break;
				// Update cursor immediately in multi-threaded context.
				next_cursor = curr_cursor + aligned_size_with_header;
				sufficient_reg = curr_reg;
				// Success.
				if (curr_reg.cursor.compare_exchange(&curr_cursor, next_cursor))
				{
					break OUTER;
				}
			} while (true);
			prev_reg = curr_reg;
			curr_reg = curr_reg.next;
		}

		if (!sufficient_reg)
		{
			sufficient_reg = push_region(self, prev_reg, aligned_size_with_header);
			old_cursor = 0;
			set_cursor(sufficient_reg, aligned_size_with_header);
		}

		char* start = (char*)&sufficient_reg.memory + old_cursor + HEADER_SIZE;
		char* ret   = mem::aligned_pointer(start, alignment);
		sz* header  = (sz*)(ret - HEADER_SIZE);
		*header = aligned_size;
		if (sufficient_reg.idx > last_reg.idx) self.last_alloc_region = sufficient_reg;
		if (init_type == ZERO)
		{
			mem::clear(ret, aligned_size);
		}
		return ret;
	$else
		GrowingArenaRegion* curr_reg       = mark_count(self) > 0 ? self.last_alloc_region : &self.root;
		GrowingArenaRegion* prev_reg       = null;
		GrowingArenaRegion* sufficient_reg = null;
		sz old_cursor @noinit;
		sz next_cursor @noinit;

		while (curr_reg)
		{
			old_cursor = cursor(curr_reg);
			if (remain_mem(curr_reg, old_cursor) >= aligned_size_with_header)
			{
				set_cursor(curr_reg, old_cursor + aligned_size_with_header);
				sufficient_reg = curr_reg;
				break;
			}
			prev_reg = curr_reg;
			curr_reg = curr_reg.next;
		}

		if (!sufficient_reg)
		{
			sufficient_reg = push_region(self, prev_reg, aligned_size_with_header);
			old_cursor = 0;
			next_cursor = aligned_size_with_header;
		}

		char* start = (char*)&sufficient_reg.memory + old_cursor + HEADER_SIZE;
		char* ret   = mem::aligned_pointer(start, alignment);
		sz* header  = (sz*)(ret - HEADER_SIZE);
		*header = aligned_size;
		if (sufficient_reg.idx > last_reg.idx) self.last_alloc_region = sufficient_reg;
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
fn void*? GrowingArenaImpl.resize(&self, void* ptr, sz new_size, sz alignment = 0) @dynamic
{
	sz aligned_new_size      = mem::aligned_offset(new_size, mem::DEFAULT_MEM_ALIGNMENT);
	GrowingArenaRegion* curr = &self.root;
	GrowingArenaRegion* reg  = null;
	sz* old_size             = (sz*)(ptr - HEADER_SIZE);
	sz alloc_size_diff       = aligned_new_size - *old_size;

	while (curr)
	{
		if (owns_ptr(curr, ptr))
		{
			reg = curr;
			break;
		}
		curr = curr.next;
	}

	assert(reg != null, "Pointer isn't managed by this allocator");

	$if THREAD_SAFE:
		sz curr_cursor = cursor(reg);
		sz new_cursor @noinit;

		do
		{
			bool last_alloc = is_last_alloc(reg, curr_cursor, ptr, *old_size);
			if (last_alloc && alloc_size_diff <= remain_mem(reg, curr_cursor))
			{
				// Extend allocation.
				new_cursor = curr_cursor + alloc_size_diff;
				if (reg.cursor.compare_exchange(&curr_cursor, new_cursor))
				{
					*old_size = aligned_new_size;
					return ptr;
				}
				else
				{
					continue;
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
	$else
		bool last_alloc = is_last_alloc(reg, reg.cursor, ptr, *old_size);
		if (last_alloc && alloc_size_diff <= remain_mem(reg, reg.cursor))
		{
			// Extend allocation.
			reg.cursor += alloc_size_diff;
			return ptr;
		}
		// Do fresh allocation.
		void* ret = self.acquire(new_size, NO_ZERO, alignment)!;
		mem::copy((char*)ret, (char*)ptr, math::min(*old_size, new_size));
		return ret;
	$endif
}

<*
 Release memory acquired using `acquire` or `resize`.
 It is not a good practice to free idxividual pointers from arena
 Consider using marks, @temp_scope, or resetting whole self.

 @require ptr != null : "Empty pointers should never be released"
*>
fn void GrowingArenaImpl.release(&self, void* ptr, bool) @dynamic
{
	GrowingArenaRegion* curr = &self.root;
	GrowingArenaRegion* reg  = null;
	sz* alloc_size           = (sz*)(ptr - HEADER_SIZE);

	while (curr)
	{
		if (owns_ptr(curr, ptr))
		{
			reg = curr;
			break;
		}
		curr = curr.next;
	}

	assert(reg != null, "Pointer isn't owned by GrowingArena allocator: ptr = %p", ptr);

	$if THREAD_SAFE:
		sz curr_cursor = cursor(reg);
		sz new_cursor @noinit;

		do
		{
			if (!is_last_alloc(reg, curr_cursor, ptr, *alloc_size))
			{
				return;
			}
			new_cursor = curr_cursor - (sz)(*alloc_size + HEADER_SIZE);
		} while (!reg.cursor.compare_exchange(&curr_cursor, new_cursor));
	$else
		if (!is_last_alloc(reg, reg.cursor, ptr, *alloc_size))
		{
			return;
		}
		reg.cursor -= (sz)(*alloc_size + HEADER_SIZE);
	$endif
}

<*
 Create a 'mark' from which you can start doing temporary allocations,
 then easily reclaim them back with 'rewidx_mark'
*>
fn GrowingArenaMark GrowingArenaImpl.save_mark(&self)
{
	GrowingArenaRegion* last_reg = self.last_alloc_region;
	assert(last_reg != null, "Last allocated region must exist");

	$if THREAD_SAFE:
		GrowingArenaMark mark @noinit;
		do
		{
			mark = { .region = last_reg, .cursor = cursor(last_reg) };
			if (self.last_alloc_region == last_reg)
			{
				self.mark_count.add(1);
				break;
			}
		} while (true);

		return mark;
	$else
		GrowingArenaMark mark = { .region = last_reg, .cursor = cursor(last_reg) };
		self.mark_count++;
		return mark;
	$endif
}

<*
 Reclaim all memory used since a call to 'save_mark'

 @require mark.region != null : "Shouldn't be null"
*>
fn void GrowingArenaImpl.rewind_mark(&self, GrowingArenaMark mark)
{
	GrowingArenaRegion* curr = self.last_alloc_region;

	while (curr && curr != mark.region)
	{
		set_cursor(curr, 0);
		curr = curr.prev;
	}

	assert(curr != null && curr == mark.region, "Should be provided region");

	set_cursor(curr, mark.cursor);
	$if THREAD_SAFE:
		self.mark_count.sub(1);
	$else
		self.mark_count--;
	$endif
	self.last_alloc_region = curr;
}

<*
 Create a temporary allocation scope around provided body, all allocated memory will be freed at the end.
*>
macro GrowingArenaImpl.@temp_scope(&self; @body())
{
	GrowingArenaMark mark = self.save_mark();
	defer self.rewind_mark(mark);
	@body();
}

<*
 Create a temporary allocation scope around provided body, all allocated memory will be freed at the end.
 Additionaly passes 'alloc' param which is Allocator interface.
*>
macro GrowingArenaImpl.@temp_scope_alloc(&self; @body(Allocator alloc))
{
	GrowingArenaMark mark = self.save_mark();
	defer self.rewind_mark(mark);
	@body(self);
}

<*
 Reclaim all used memory, allowing for reuse.
*>
fn void GrowingArenaImpl.reset(&self)
{
	GrowingArenaRegion* curr = &self.root;
	while (curr)
	{
		set_cursor(curr, 0);
		curr = curr.next;
	}
	self.last_alloc_region = &self.root;
}

<*
 Free all the memory storage of arena and return it to backing allocator.

 @require self != null : "Should be initialized"
*>
fn void GrowingArenaImpl.free(&self)
{
	if (self)
	{
		// Start from the second one.
		GrowingArenaRegion* curr = self.root.next;
		GrowingArenaRegion* next = null;
		while (curr)
		{
			next = curr.next;
			alloc::free(self.backing_alloc, curr);
			curr = next;
		}
		alloc::free(self.backing_alloc, self);
		self = null;
	}
}

<*
 Set the size that will be used as 'min' capacity boundary for newly created arena region.

 @require min_size >= MIN_REGION_CAPACITY : "Should be greater than min"
*>
fn void GrowingArenaImpl.set_min_region_capacity(&self, sz min_size) @inline
{
	self.min_region_capacity = min_size;
}

<*
 Implements 'Printable' interface.
*>
fn sz? GrowingArenaImpl.to_format(&self, Formatter* fmt) @dynamic
{
	sz total                 = fmt.print("GrowingArena allocator info: [cursor : capacity]")!;
	GrowingArenaRegion* curr = &self.root;

	while (curr)
	{
		fmt.printf("\n\t[%s : %s], remain: %s", curr.cursor, curr.capacity, remain_mem(curr, cursor(curr)))!;
		curr = curr.next;
	}

	return total;
}

// Mimic std api without virtual function call overhead.

macro GrowingArenaImpl.alloc_array(&self, $Type, sz count) => _alloc_array{$Type, THREAD_SAFE}(self, count);

fn AllocElemType[] _alloc_array(GrowingArenaImpl{THREAD_SAFE}* self, sz count)<AllocElemType, THREAD_SAFE>
{
	sz size = AllocElemType::size * count;
	return ((AllocElemType*)self.acquire(size, NO_ZERO)!!)[:count];
}

macro GrowingArenaImpl.new_array(&self, $Type, sz count) => _new_array{$Type, THREAD_SAFE}(self, count);

fn AllocElemType[] _new_array(GrowingArenaImpl{THREAD_SAFE}* self, sz count)<AllocElemType, THREAD_SAFE>
{
	sz size = AllocElemType::size * count;
	return ((AllocElemType*)self.acquire(size, ZERO)!!)[:count];
}

<*
 @require @kidxof(old_slice) == SLICE : "Must be slice"
*>
macro GrowingArenaImpl.realloc_array(
	&self,
	old_slice,
	sz new_count
) => _realloc_array{$Typeof(old_slice[0]), THREAD_SAFE}(self, old_slice, new_count);

fn AllocElemType[] _realloc_array(
	GrowingArenaImpl{THREAD_SAFE}* self,
	AllocElemType[] old_slice,
	sz new_count
)<AllocElemType, THREAD_SAFE>
{
	sz new_size = AllocElemType::size * new_count;
	return ((AllocElemType*)self.resize(old_slice.ptr, new_size)!!)[:new_count];
}

macro GrowingArenaImpl.alloc_smart_array(&self, $Type, sz count) => _alloc_smart_array{$Type, THREAD_SAFE}(self, count);

fn SmartSlice{AllocElemType} _alloc_smart_array(
	GrowingArenaImpl{THREAD_SAFE}* self,
	sz count
)<AllocElemType, THREAD_SAFE>
{
	SmartSlice{AllocElemType} res @noinit;
	sz size = AllocElemType::size * count;
	res.items = ((AllocElemType*)self.acquire(size, NO_ZERO)!!)[:count];
	res.size = 0;
	return res;
}

macro GrowingArenaImpl.new_smart_array(&self, $Type, sz count) => _new_smart_array{$Type, THREAD_SAFE}(self, count);

fn SmartSlice{AllocElemType} _new_smart_array(GrowingArenaImpl{THREAD_SAFE}* self, sz count)<AllocElemType, THREAD_SAFE>
{
	SmartSlice{AllocElemType} res @noinit;
	sz size = AllocElemType::size * count;
	res.items = ((AllocElemType*)self.acquire(size, ZERO)!!)[:count];
	res.size = 0;
	return res;
}

macro GrowingArenaImpl.realloc_smart_array(
	&self,
	old_arr,
	sz new_count
) => _realloc_smart_array{$Typeof(old_arr.items[0]), THREAD_SAFE}(self, old_arr, new_count);

fn SmartSlice{AllocElemType} _realloc_smart_array(
	GrowingArenaImpl{THREAD_SAFE}* self,
	SmartSlice{AllocElemType} old_arr,
	sz new_count
)<AllocElemType, THREAD_SAFE>
{
	SmartSlice{AllocElemType} res @noinit;
	sz new_size = AllocElemType::size * new_count;
	res.items = ((AllocElemType*)self.resize(old_arr.items.ptr, new_size)!!)[:new_count];
	res.size = new_count;
	return res;
}

fn void* GrowingArenaImpl.malloc(&self, sz size)
{
	return self.acquire(size, NO_ZERO)!!;
}

fn void* GrowingArenaImpl.calloc(&self, sz size)
{
	return self.acquire(size, ZERO)!!;
}

fn void* GrowingArenaImpl.realloc(&self, void* ptr, sz new_size)
{
	return self.resize(ptr, new_size)!!;
}

// Only for compatibility reasons and external interfacing with C.
fn void* GrowingArenaImpl.c_realloc(&self, void* ptr, sz new_size)
{
	if (!ptr)
	{
		return self.malloc(new_size);
	}
	else if (new_size == 0)
	{
		// We don't want free on arenas, just use temp_scope.
		return null;
	}
	return self.resize(ptr, new_size)!!;
}

macro GrowingArenaImpl.alloc(&self, $Type) => _alloc{$Type, THREAD_SAFE}(self);

fn AllocType* _alloc(GrowingArenaImpl{THREAD_SAFE}* self)<AllocType, THREAD_SAFE> @private
{
	return self.acquire(AllocType::size, NO_ZERO)!!;
}

<*
 @require @kidxof(val) != POINTER : "Should pass by value"
*>
macro GrowingArenaImpl.clone(&self, val) => _clone{$Typeof(val), THREAD_SAFE}(self, val);

fn CloneType* _clone(GrowingArenaImpl{THREAD_SAFE}* self, CloneType val)<CloneType, THREAD_SAFE> @private
{
	CloneType* res = self.alloc(CloneType);
	*res = val;
	return res;
}

// ------ Private API ------

<*
 Add new region to the self.

 @require last_reg != null : "Shouldn't be null"
*>
fn GrowingArenaRegion* push_region(GrowingArenaImpl* self, GrowingArenaRegion* last_reg, sz capacity) @private
{
	last_reg.next = allocate_region(self, capacity, last_reg.idx + 1);
	last_reg.next.prev = last_reg;
	return last_reg.next;
}

<*
 Allocate new arena region.
*>
fn GrowingArenaRegion* allocate_region(GrowingArenaImpl* self, sz capacity, sz idx) @private
{
	sz cap                  = math::max(capacity, self.min_region_capacity);
	sz aligned_cap          = mem::aligned_offset(cap, mem::DEFAULT_MEM_ALIGNMENT);
	GrowingArenaRegion* reg = alloc::alloc_with_padding(self.backing_alloc, GrowingArenaRegion, aligned_cap)!!;
	set_capacity(reg, aligned_cap);
	set_cursor(reg, 0);
	reg.next = null;
	reg.prev = null;
	reg.idx = idx;
	return reg;
}

<*
 Tell if provided pointer is owned by this allocator memory.
*>
fn bool owns_ptr(GrowingArenaRegion* reg, void* ptr) @inline @private
{
	return ((char*)ptr >= (char*)&reg.memory) && ((char*)ptr < ((char*)&reg.memory + capacity(reg)));
}

<*
 Tell how much free memory arena region has.
*>
fn sz remain_mem(GrowingArenaRegion* reg, sz cursor) @inline @private
{
	return capacity(reg) - cursor;
}

<*
 Tell if provided allocation is last in the region.
*>
fn bool is_last_alloc(GrowingArenaRegion* reg, sz cursor, void* ptr, sz alloc_size) @inline @private
{
	sz alloc_cursor = ((char*)ptr + alloc_size) - (char*)&reg.memory;
	return alloc_cursor == cursor;
}

macro sz cursor(GrowingArenaRegion* reg) @private
{
	$if THREAD_SAFE:
		return reg.cursor.load();
	$else
		return reg.cursor;
	$endif
}

macro void set_cursor(GrowingArenaRegion* reg, sz val) @private
{
	$if THREAD_SAFE:
		reg.cursor.store(val);
	$else
		reg.cursor = val;
	$endif
}

macro sz capacity(GrowingArenaRegion* reg) @private
{
	$if THREAD_SAFE:
		return reg.capacity.load();
	$else
		return reg.capacity;
	$endif
}

macro void set_capacity(GrowingArenaRegion* reg, sz val) @private
{
	$if THREAD_SAFE:
		reg.capacity.store(val);
	$else
		reg.capacity = val;
	$endif
}

macro sz mark_count(GrowingArenaImpl* self) @private
{
	$if THREAD_SAFE:
		return self.mark_count.load();
	$else
		return self.mark_count;
	$endif
}

macro void set_mark_count(GrowingArenaImpl* self, sz val) @private
{
	$if THREAD_SAFE:
		self.mark_count.store(val);
	$else
		self.mark_count = val;
	$endif
}

