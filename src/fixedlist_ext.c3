module std::collections::fixedlist <Type, MAX_SIZE>;
import ext;

<*
 @require new_cap <= MAX_SIZE : "Shouldn't exceed capacity"
*>
fn void FixedList.resize(&list, sz new_cap) @inline
{
	list.size = new_cap;
}

fn void FixedList.resize_to_cap(&list) @inline
{
	list.size = MAX_SIZE;
}

<*
 @require list.size + add_cap <= MAX_SIZE : "Shouldn't exceed capacity"
*>
fn Type[] FixedList.reserve_range(&list, sz add_cap)
{
	sz start = list.size;
	list.size += add_cap;
	return list.entries[start..list.size - 1];
}

fn void FixedList.fill(&list, Type val)
{
	foreach (&entry : list.view())
	{
		*entry = val;
	}
}

fn void FixedList.fill_through_capacity(&list, Type val)
{
	foreach (&entry : list.entries)
	{
		*entry = val;
	}
}

<*
 @require ind < list.size : "Should not exceed bounds"
*>
fn void FixedList.remove_unordered(&list, sz ind)
{
	swap_ptrs(&list[ind], &list[list.size - 1]);
	list.size--;
}

<*
 @require list.size + move_count <= list.entries.len : "Should not exceed bounds"
*>
fn void FixedList.move_forward(&list, sz move_count) @inline
{
	list.size += move_count;
}

<*
 @require list.size - move_count >= 0 : "Should not exceed bounds"
*>
fn void FixedList.move_backward(&list, sz move_count) @inline
{
	list.size -= move_count;
}

fn Type[] FixedList.view(&list) => list.array_view(); 

<*
 @require end < list.size : "Should not be more than or equal to size"
*>
fn Type[] FixedList.view_range(&list, sz start, sz end) @inline
{
	return list.entries[start..end];
}

<*
 @require (start + len) <= list.size : "Should not be more than or equal to size"
*>
fn Type[] FixedList.view_range_len(&list, sz start, sz len) @inline
{
	return list.entries[start:len];
}

<*
 @require (start + len) <= MAX_SIZE : "Should not be more than or equal to capacity"
*>
fn Type[] FixedList.view_range_len_through_cap(&list, sz start, sz len) @inline
{
	return list.entries[start:len];
}

<*
 @require self.size > 0 : "Shouldn't be empty"
*>
fn Type* FixedList.first_ref(&self) @inline
{
	return &self.entries[0];
}

<*
 @require self.size > 0 : "Shouldn't be empty"
*>
fn Type* FixedList.last_ref(&self) @inline
{
	return &self.entries[self.size - 1];
}

macro sz FixedList.capacity(&self) => MAX_SIZE;
