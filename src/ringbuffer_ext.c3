<*
 @require types::is_int($Typeof(CAPACITY)) && CAPACITY > 0 : "Capacity must be bigger than 0"
*>
module std::collections::ringbuffer <Type, CAPACITY>;
import std::io, std::math;
import ext;

macro sz RingBuffer.capacity(&self) => CAPACITY;

<*
 Performs subsequent 'push' calls on each value in the array or slice
 Safe means it wouldn't overwrite existing items.
 @param [in] items : "Array to push elements from"
 @return "Items that doesn't fit into the remain space of the buffer"
*>
fn Type[] RingBuffer.push_all_safe(&self, Type[] items)
{
	sz pushed = math::min(items.len, self.remain_count());
	foreach (e : items[:pushed]) self.push(e);
	return pushed < items.len ? items[pushed..] : {};
}

<*
 Pushes a new element to the end of the ring list.
 Safe means it wouldn't overwrite existing items.
 @return "true - if item is pushed, otherwise false"
*>
fn bool RingBuffer.push_safe(&self, Type element)
{
	if (self.remain_count())
	{
		self.push(element) @inline;
		return true;
	}
	return false;
}

<*
 Pops the element from the start of the ringbuffer.
 Caller ensures that its not empty.
 @require !self.is_empty() : "Shouldn't be empty"
*>
fn Type RingBuffer.pop_first_ensure(&self)
{
	defer @wrap_inc(self.head, CAPACITY);
	return self.buf[self.head];
}

<*
 Count of empty elements (available) in the backing buffer.
*>
macro sz RingBuffer.remain_count(&self) => CAPACITY - self.len();
