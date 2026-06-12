module ext::collections::thread_pool;
import std::thread;

// BUG: when task executed on the thread and wants to await, it goes infinite.
// TODO: await on specific thread.

const THREAD_TEMP_MEM_AMOUNT = 1 << 14; // 16kb

struct ThreadTask
{
	ThreadFn func;
	void* arg;
}

alias ThreadFn = fn void(void* task_data);

<*
 @require MAX_THREADS > 0 && MAX_TASKS > 0 : "Should be at least 1"
*>
module ext::collections::thread_pool <MAX_THREADS, MAX_TASKS>;
import std::thread @norecurse;
import std::math @norecurse;
import std::io @norecurse;
import std::collections::ringbuffer;
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
	RingBuffer{ThreadTask, MAX_TASKS} queue;
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
	Allocator mem;
	Allocator tmem;
}

<*
 @require !self.is_initialized() : "Pools must not be already initialized"
*>
fn void? ThreadPool.init(
	&self,
	Allocator thread_main_alloc = mem,
	Allocator thread_temp_alloc = tmem,
	ThreadSettings thread_settings = {},
)
{
	defer catch self.destroy();

	self.alive_thread_count = MAX_THREADS;
	self.initialized = true;
	self.mutex.init()!;
	self.cond_task_acquired.init()!;
	self.cond_task_finished.init()!;
	self.cond_collect.init()!;

	self.queue.init();

	self.threads_working = { };

	foreach (i, &thread : self.threads)
	{
		ThreadCreateData thread_data = { self, i, thread_main_alloc, thread_temp_alloc };
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
	self.mutex.@lock_scope()
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

	self.mutex.@lock_scope()
	{
		while (true)
		{
			pushed = self.queue.push_safe(task);
			// Signal to the threads that work is available.
			if (pushed)
			{
				self.cond_task_acquired.broadcast();
				return;
			}
			self.cond_task_finished.wait(&self.mutex);
		}
	};
}

<*
 Submits multiple tasks to the pool.
*>
fn void ThreadPool.submit_task_many(&self, ThreadTask[] tasks)
{
	ThreadTask[] remain_tasks = tasks;
	sz old_len @noinit;

	self.mutex.@lock_scope()
	{
		while (remain_tasks.len)
		{
			old_len = remain_tasks.len;
			remain_tasks = self.queue.push_all_safe(remain_tasks);
			if (remain_tasks.len < old_len)
			{
				self.cond_task_acquired.broadcast();
				if (remain_tasks.len == 0) return;
			}
			self.cond_task_finished.wait(&self.mutex);
		}
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

	mem = thread_data.mem;
	tmem = thread_data.tmem;

	@pool_init(tmem, THREAD_TEMP_MEM_AMOUNT)
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
			task.func(task.arg);
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
			if (!threads_idle_count(self) && !threads_idle_count(self))
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
