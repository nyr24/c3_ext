module std::thread;

macro void Mutex.@lock_scope(&self; @body())
{
	self.lock();
	defer self.unlock();
	@body();
}
