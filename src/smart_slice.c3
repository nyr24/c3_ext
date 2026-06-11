module ext::collections::smart_slice <Type>;

struct SmartSlice
{
	Type[] items;
	sz size;
}

const INIT_CAPACITY @local = 8;

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

fn Type[] SmartSlice.raw(&self) @inline
{
	return self.items[:self.size];
}
