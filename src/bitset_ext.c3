<*
 @require SIZE > 0 : "The size of the bitset in bits must be at least 1"
 @require SIZE / (uint::size * 8) < uint::max
*>
module std::collections::bitset <SIZE>;

alias InnerType = $reflect(BitSet.data).type.inner;

macro sz BitSet.set_count(&self) => self.cardinality();

<*
 Tells if at least 1 bit is set.
*>
fn bool BitSet.some_set(&self)
{
	sz n;
	foreach (x : self.data)
	{
		n += x.popcount();
		if (n > 0) return true;
	}
	return false;
}

<*
 Tells if at least 1 bit is unset.
*>
fn bool BitSet.some_unset(&self)
{
	sz n;
	foreach (x : self.data)
	{
		n += x.popcount();
		if (n < bitsizeof(InnerType)) return true;
	}
	return false;
}
