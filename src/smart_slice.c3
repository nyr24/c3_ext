module ext::collections::smart_slice <Type>;

struct SmartSlice
{
	Type[] items;
	sz size;
}

<*
 @require self.size < items.len : "Shouldn't exceed capacity"
*>
fn SmartSlice{Type} create(&self, Allocator alloc, sz len) @inline
{
	SmartSlice{Type} res = { .items = alloc::alloc_array(alloc, Type, len), .size = len };
	return res;
}

<*
 @require self.size < items.len : "Shouldn't exceed capacity"
*>
fn SmartSlice{Type} create_with_values(&self, Allocator alloc, Type[] values) @inline
{
	SmartSlice{Type} res = { .items = alloc::alloc_array(alloc, Type, values.len), .size = values.len };
	foreach (i, &item : res.items)
	{
		*item = values[i];
	}
	return res;
}

<*
 @require self.size < items.len : "Shouldn't exceed capacity"
*>
fn void SmartSlice.push(&self, Type item) @inline
{
	self.items[self.size++] = item;
}

<*
 @require self.size < items.len : "Shouldn't exceed capacity"
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

fn void SmartSlice.free(&self, Allocator alloc)
{
	alloc::free(alloc, self.items);
	self.size = 0;
}
