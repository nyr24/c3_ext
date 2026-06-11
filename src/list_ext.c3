module std::collections::list <Type>;
import ext;

<*
 @require new_size <= list.capacity : "Should not exceed current capacity"
*>
fn void List.resize(&list, sz new_size) @inline
{
	list.size = new_size;
}

fn void List.resize_to_cap(&list) @inline
{
	list.size = list.capacity;
}

fn Type[] List.reserve_range(&list, sz add_cap)
{
	list.reserve(add_cap);
	sz start = list.size;
	list.size += add_cap;
	return list.entries[start..list.size - 1];
}

<*
 @require list.size + move_count <= list.capacity : "Should not exceed bounds"
*>
fn void List.move_forward(&list, sz move_count) @inline
{
	list.size += move_count;
}

<*
 @require list.size - move_count >= 0 : "Should not exceed bounds"
*>
fn void List.move_backward(&list, sz move_count) @inline
{
	list.size -= move_count;
}

fn Type[] List.view(&list) => list.array_view();

<*
 @require end < list.size : "Should not be more than or equal to size"
*>
fn Type[] List.view_range(&list, sz start, sz end) @inline
{
	return list.entries[start..end];
}

<*
 @require (start + len) <= list.size : "Should not be more than or equal to size"
*>
fn Type[] List.view_range_len(&list, sz start, sz len) @inline
{
	return list.entries[start:len];
}

<*
 @require (start + len) <= list.capacity : "Should not be more than or equal to capacity"
*>
fn Type[] List.view_range_len_through_cap(&list, sz start, sz len) @inline
{
	return list.entries[start:len];
}

<*
 @require self.size > 0 : "Shouldn't be empty"
*>
fn Type* List.first_ref(&self) @inline
{
	return &self.entries[0];
}

<*
 @require self.size > 0 : "Shouldn't be empty"
*>
fn Type* List.last_ref(&self) @inline
{
	return &self.entries[self.size - 1];
}

fn void List.fill(&list, Type val)
{
	foreach (&entry : list.view())
	{
		*entry = val;
	}
}

fn void List.fill_through_capacity(&list, Type val)
{
	foreach (&entry : list.entries[:list.capacity])
	{
		*entry = val;
	}
}
