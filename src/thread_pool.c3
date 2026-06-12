module ext::collections::thread_pool;
import std::thread;

struct ThreadTask
{
	ThreadFn func;
	void* arg;
	Allocator alloc;
}

alias ThreadFn = fn void(void* task_data);

<*
 @require MAX_THREADS > 0 && MAX_TASKS > 0 : "Should be at least 1"
*>
module ext::collections::thread_pool <MAX_THREADS, MAX_TASKS>;
import std::thread @norecurse;
import std::math @norecurse;
import std::io @norecurse;
import std::collections::deque;
import std::collections::bitset;

<*
 Thread pool data structure, manages a set of threads which a running indefinitely, and sleep while waiting for the tasks.
*>
struct ThreadPool
{
	Mutex mutex;
	ConditionVariable cond_task_acquired;
	ConditionVariable cond_task_finished;
	ConditionVariable cond_collect;
	bitstruct : sz
	{
		bool initialized : 0..0;
		bool stop : 1..1;
		bool stop_now : 2..2;
		sz alive_thread_count : 3..(bitsizeof(sz) - 1);
	}
	Deque{ThreadTask} queue;
	Thread[MAX_THREADS] threads;
	BitSet{MAX_THREADS} threads_working;
}

<*
 Passed to the thread upon creation.
*>
struct ThreadCreateData @local
{
	ThreadPool* tpool;
	// Corresponds to 'threads_working' states array
	sz idx;
	sz temp_pool_capacity;
	Allocator alloc;
}

const DEFAULT_TASK_QUEUE_CAPACITY = 64;
const DEFAULT_TEMP_POOL_CAPACITY = 1ul << 16; // 65kb

<*
 @require !self.is_initialized() : "Pools must not be already initialized"
*>
fn void? ThreadPool.init(&self, Allocator alloc, sz task_queue_cap = DEFAULT_TASK_QUEUE_CAPACITY, sz temp_pool_capacity = DEFAULT_TEMP_POOL_CAPACITY, ThreadSettings thread_settings = { })
{
	self.alive_thread_count = MAX_THREADS;
	self.initialized = true;
	self.mutex.init()!;
	defer catch self.mutex.destroy();
	self.cond_task_acquired.init()!;
	defer catch self.cond_task_acquired.destroy();
	self.cond_task_finished.init()!;
	defer catch self.cond_task_finished.destroy();
	self.cond_collect.init()!;
	defer catch self.cond_collect.destroy();

	self.queue.init(alloc, task_queue_cap);
	defer catch self.queue.free();
	self.threads_working = { };

	defer catch self.stop = true;

	foreach (i, &thread : self.threads)
	{
		ThreadCreateData thread_data = { self, i, temp_pool_capacity, alloc };
		thread.create(&worker, &thread_data, thread_settings)!;
		// The thread resources will be cleaned up when the thread exits.
		thread.detach()!;
	}
}

<*
 Awaits all tasks.
 WARN: Can't be called inside a threadpool thread, will wait forever then.

 @require self.is_initialized() : "Pools must be already initialized"
*>
fn void ThreadPool.await_all(&self)
{
	self.mutex.@in_lock()
	{
		while (!self.queue.is_empty() || threads_working_count(self))
		{
			self.cond_task_finished.wait(&self.mutex);
		}
	};
}

<*
 Awaits on the 'done' condition, for task.
 User should call it in a while loop, to see if his specific task is finished.

 @require self.is_initialized() : "Pools must be already initialized"
*>
fn void ThreadPool.await_until_some_done(&self) @inline
{
	if (threads_working_count(self))
	{
		self.cond_task_finished.wait(&self.mutex);
	}
}

<*
 Submits a new task to the pool.
*>
fn void ThreadPool.submit_task(&self, ThreadTask task)
{
	bool pushed = false;

	self.mutex.@in_lock()
	{
		self.queue.push(task);
		self.cond_task_acquired.broadcast();
	};
}

<*
 Submits multiple tasks to the pool.
*>
fn void ThreadPool.submit_task_many(&self, ThreadTask[] tasks)
{
	ThreadTask[] remain_tasks = tasks;
	sz old_len @noinit;

	self.mutex.@in_lock()
	{
		self.queue.push_all(remain_tasks);
		self.cond_task_acquired.broadcast();
		return;
	};
}

<*
 Internal procedure for running threads.
*>
fn int worker(void* arg) @local
{
	ThreadCreateData* thread_data = arg;
	sz thread_idx                 = thread_data.idx;
	ThreadPool* self              = thread_data.tpool;

	@pool_init(thread_data.alloc, thread_data.temp_pool_capacity)
	{
		while (true)
		{
			self.mutex.lock();
			// Wait for work.
			while (self.queue.is_empty())
			{
				if (self.stop)
				{
					// Shutdown requested.
					self.alive_thread_count--;
					self.mutex.unlock();
					return 0;
				}

				self.threads_working[thread_idx] = false;
				self.cond_task_acquired.wait(&self.mutex);

				if (self.stop_now)
				{
					// Shutdown requested.
					self.alive_thread_count--;
					self.mutex.unlock();
					return 0;
				}
			}
			ThreadTask task = self.queue.pop_first_ensure();
			self.threads_working[thread_idx] = true;
			self.mutex.unlock();
			// Process the task.
			task.func(&task);
			self.cond_task_finished.broadcast();
		}
	};
}

<*
 Stop all the threads and cleanup the pool.
 Any pending work will be dropped.
*>
fn void ThreadPool.destroy(&self)
{
	@shutdown(self, self.stop_now);
}

<*
 Stop all the threads and cleanup the pool.
 Any pending work will be processed.
*>
fn void ThreadPool.stop_and_destroy(&self)
{
	@shutdown(self, self.stop);
}

macro void @shutdown(ThreadPool* self, bool #stop_flag) @local
{
	if (self.initialized)
	{
		self.mutex.lock();
		#stop_flag = true;
		self.cond_task_acquired.broadcast();
		self.mutex.unlock();
		// Wait for all threads to shutdown.
		while (true)
		{
			self.mutex.lock();
			defer self.mutex.unlock();
			if (!threads_idle_count(self))
			{
				break;
			}
			self.cond_task_acquired.signal();
		}
		self.mutex.destroy();
		self.cond_task_acquired.destroy();
		self.cond_task_finished.destroy();
		self.cond_collect.destroy();
		self.initialized = false;
		self.queue.free();
	}
}

<*
 Tells if thread pool is initialized.
*>
fn bool ThreadPool.is_initialized(&self) @inline
{
	return self.initialized;
}

macro sz threads_idle_count(ThreadPool* self) @local
{
	return MAX_THREADS - self.threads_working.set_count();
}

macro sz threads_working_count(ThreadPool* self) @local
{
	return self.threads_working.set_count();
}
