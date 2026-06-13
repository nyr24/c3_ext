module ext::collections::smart_slice <Type>;
import std::io @norecurse;

faultdef NOT_ENOUGH_SPACE;

struct SmartSlice (Printable)
{
	Type[] items;
	sz size;
}

fn SmartSlice{Type} create(Allocator alloc, sz len) @inline
{
	SmartSlice{Type} res = { .items = alloc::alloc_array(alloc, Type, len), .size = len };
	return res;
}

fn SmartSlice{Type} create_with_values(Allocator alloc, Type[] values) @inline
{
	SmartSlice{Type} res = { .items = alloc::alloc_array(alloc, Type, values.len), .size = values.len };
	foreach (i, &item : res.items)
	{
		*item = values[i];
	}
	return res;
}

<*
 @require self.size < self.items.len : "Shouldn't exceed capacity"
*>
fn void SmartSlice.push(&self, Type item) @inline
{
	self.items[self.size++] = item;
}

fn void? SmartSlice.push_try(&self, Type item) @inline
{
	if (self.size == self.items.len) return NOT_ENOUGH_SPACE~;
	self.items[self.size++] = item;
}

<*
 @require self.size < self.items.len : "Shouldn't exceed capacity"
*>
fn Type* SmartSlice.pull(&self) @inline
{
	defer self.size++;
	return &self.items[self.size];
}

fn void SmartSlice.reset(&self) @inline
{
	self.size = 0;
}

fn Type[] SmartSlice.view(&self) @inline
{
	return self.items[:self.size];
}

<*
 @require idx >= 0 && idx < self.size : "Bounds check failed"
*>
fn Type SmartSlice.get(&self, sz idx) @operator([]) @inline
{
	return self.items[idx];
}

<*
 @require idx >= 0 && idx < self.size : "Bounds check failed"
*>
fn Type* SmartSlice.get_ref(&self, sz idx) @operator(&[]) @inline
{
	return &self.items[idx];
}

<*
 @require idx >= 0 && idx < self.size : "Bounds check failed"
*>
fn void SmartSlice.set(&self, sz idx, Type val) @operator([]=) @inline
{
	self.items[idx] = val;
}

fn sz SmartSlice.len(&self) @operator(len) @inline
{
	return self.size;
}

fn sz? SmartSlice.to_format(&self, Formatter* fmt) @dynamic
{
	sz total = fmt.printf("[")!;
	foreach (i, item : self)
	{
		total += fmt.printf("%s", item)!;
		if (i != self.size) total += fmt.print(" ")!;
	}
	fmt.print("]")!;
	return total;
}

fn void SmartSlice.free(&self, Allocator alloc)
{
	alloc::free(alloc, self.items);
	self.size = 0;
}
