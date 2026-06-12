module std::collections::deque <Type>;
import ext::util;

<*
 More optimized version of 'pop_front', when we know that the size is not 0.

 @require !self.is_empty() : "Size should be greater than 0"
*>
fn Type Deque.pop_first_ensure(Deque* self)
{
	Type elem = self.entries[self.start];
	self.start = wrap_inc(self.start, self.capacity);
	self.size--;
	return elem;
}
