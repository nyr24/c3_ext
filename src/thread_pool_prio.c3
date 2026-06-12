module ext::collections::thread_pool_prio;
import std::thread;

// BUG: when task executed on the thread and wants to await, it goes infinite.
// TODO: await on specific thread.

struct ThreadTask
{
	ThreadFn func;
	void* arg;
}

<*
 User should fill this structure to submit multiple tasks.
*>
struct ThreadTaskPack
{
	TaskPriority priority;
	ThreadTask[] tasks;
}

<*
 Collects all the data pool needs for synchronization.
 Only for internal use.
*>
struct PoolData @private
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
}

<*
 Task priority.
 LOW - For IO / background tasks.
 HIGH - For computation-intensive, urgent tasks.
*>
enum TaskPriority : (ThreadPriority thread_prio)
{
	// For IO / background tasks.
	LOW  { DEFAULT },
	// For computation-intensive, urgent tasks.
	HIGH { REALTIME },
}

alias ThreadFn = fn void(void* task_data);

<*
 @require HIGH_THREADS > 0 && LOW_THREADS > 0 && HIGH_TASKS > 0 && LOW_TASKS > 0 : "Should be at least 1"
*>
module ext::collections::thread_pool_prio <HIGH_THREADS, LOW_THREADS, HIGH_TASKS, LOW_TASKS>;
import std::thread @norecurse;
import std::math @norecurse;
import std::io @norecurse;
import std::collections::ringbuffer;
import std::collections::bitset;

<*
 Thread pool root structure which manages 2 separate pools: high priority, and low priority.
*>
struct ThreadPoolPrio
{
	PoolData high_pool;
	PoolData low_pool;
	RingBuffer{ThreadTask, HIGH_TASKS} high_queue;
	RingBuffer{ThreadTask, LOW_TASKS} low_queue;
	Thread[HIGH_THREADS] high_threads;
	Thread[LOW_THREADS] low_threads;
	BitSet{HIGH_THREADS} high_threads_working;
	BitSet{LOW_THREADS} low_threads_working;
}

<*
 Passed to the thread upon creation.
*>
struct ThreadCreateData @local
{
	ThreadPoolPrio* tpool;
	// Corresponds to '[low|high]_threads_working' states array
	sz idx;
	Allocator mem;
	Allocator tmem;
	sz temp_pool_mem_amount;
}

<*
 @require !self.is_initialized() : "Pools must not be already initialized"
*>
fn void? ThreadPoolPrio.init(
	&self,
	Allocator thread_main_alloc = mem,
	Allocator thread_temp_alloc = tmem,
	sz temp_pool_mem_amount = 4096,
	sz stack_size_low = 0,
	sz stack_size_high = 0
)
{
	defer catch self.destroy();

	PoolData* pool = &self.high_pool;
	pool.alive_thread_count = HIGH_THREADS;
	pool.initialized = true;
	pool.mutex.init()!;
	pool.cond_task_acquired.init()!;
	pool.cond_task_finished.init()!;
	pool.cond_collect.init()!;

	pool = &self.low_pool;
	pool.alive_thread_count = LOW_THREADS;
	pool.initialized = true;
	pool.mutex.init()!;
	pool.cond_task_acquired.init()!;
	pool.cond_task_finished.init()!;
	pool.cond_collect.init()!;

	self.high_queue.init();
	self.low_queue.init();

	self.high_threads_working = { };
	self.low_threads_working = { };

	foreach (i, &thread : self.high_threads)
	{
		ThreadCreateData thread_data = { self, i, thread_main_alloc, thread_temp_alloc, temp_pool_mem_amount };
		thread.create(&process_high_prio_task, &thread_data, { stack_size_high, TaskPriority.HIGH.thread_prio })!;
		// The thread resources will be cleaned up when the thread exits.
		thread.detach()!;
	}

	foreach (i, &thread : self.low_threads)
	{
		ThreadCreateData thread_data = { self, i, thread_main_alloc, thread_temp_alloc, temp_pool_mem_amount };
		thread.create(&process_low_prio_task, &thread_data, { stack_size_low, TaskPriority.LOW.thread_prio })!;
		// The thread resources will be cleaned up when the thread exits.
		thread.detach()!;
	}
}

<*
 Awaits all tasks in both queues.

 @require self.is_initialized() : "Pools must be already initialized"
*>
fn void ThreadPoolPrio.await_all(&self)
{
	PoolData* pool = &self.high_pool;

	pool.mutex.@lock_scope()
	{
		while (!self.high_queue.is_empty() || high_threads_working(self))
		{
			pool.cond_task_finished.wait(&pool.mutex);
		}
	};

	pool = &self.low_pool;
	pool.mutex.@lock_scope()
	{
		while (!self.low_queue.is_empty() || low_threads_working(self))
		{
			pool.cond_task_finished.wait(&pool.mutex);
		}
	};
}

<*
 Awaits all tasks in the queue with specified priority.

 @require self.is_initialized() : "Pools must be already initialized"
*>
fn void ThreadPoolPrio.await_with_priority(&self, TaskPriority priority)
{
	if (priority == HIGH)
	{
		PoolData* pool = &self.high_pool;
		pool.mutex.lock();
		defer pool.mutex.unlock();
		while (!self.high_queue.is_empty() || high_threads_working(self))
		{
			pool.cond_task_finished.wait(&pool.mutex);
		}
	}
	else
	{
		PoolData* pool = &self.low_pool;
		pool.mutex.lock();
		defer pool.mutex.unlock();
		while (!self.low_queue.is_empty() || low_threads_working(self))
		{
			pool.cond_task_finished.wait(&pool.mutex);
		}
	}
}

<*
 Awaits on the 'done' condition, for high priority task.
 User should call it in a while loop, to see if his specific task is finished.

 @require self.is_initialized() : "Pools must be already initialized"
*>
fn void ThreadPoolPrio.await_until_some_done_high_prio(&self) @inline
{
	PoolData* pool = &self.high_pool;
	pool.mutex.@lock_scope()
	{
		if (high_threads_working(self))
		{
			pool.cond_task_finished.wait(&pool.mutex);
		}
	};
}

<*
 Awaits on the 'done' condition, for low priority task.
 User should call it in a while loop, to see if his specific task is finished.

 @require self.is_initialized() : "Pools must be already initialized"
*>
fn void ThreadPoolPrio.await_until_some_done_low_prio(&self) @inline
{
	PoolData* pool = &self.low_pool;
	pool.mutex.@lock_scope()
	{
		pool.cond_task_finished.wait(&pool.mutex);
	};
}

<*
 Submits a new task to the pool.
*>
fn void ThreadPoolPrio.submit_task(&self, ThreadTask task, TaskPriority priority)
{
	if (priority == HIGH)
	{
		PoolData* pool = &self.high_pool;
		pool.mutex.lock();
		defer pool.mutex.unlock();
		bool pushed = false;

		while (true)
		{
			pushed = self.high_queue.push_safe(task);
			// Signal to the threads that work is available.
			if (pushed)
			{
				pool.cond_task_acquired.broadcast();
				return;
			}
			pool.cond_task_finished.wait(&pool.mutex);
		}
	}
	else
	{
		PoolData* pool = &self.low_pool;
		pool.mutex.lock();
		defer pool.mutex.unlock();
		bool pushed = false;

		while (true)
		{
			pushed = self.low_queue.push_safe(task);
			// Signal to the threads that work is available.
			if (pushed)
			{
				pool.cond_task_acquired.broadcast();
				return;
			}
			pool.cond_task_finished.wait(&pool.mutex);
		}
	}
}

<*
 Submits multiple tasks to the pool.
*>
fn void ThreadPoolPrio.submit_task_many(&self, ThreadTaskPack[] task_packs)
{
	PoolData* pool @noinit;
	ThreadTask[] remain_tasks @noinit;
	sz old_len @noinit;

	foreach OUT: (pack : task_packs)
	{
		if (pack.priority == HIGH)
		{
			pool = &self.high_pool;
			remain_tasks = pack.tasks;
			pool.mutex.lock();
			defer pool.mutex.unlock();

			while (remain_tasks.len)
			{
				old_len = remain_tasks.len;
				remain_tasks = self.high_queue.push_all_safe(remain_tasks);
				if (remain_tasks.len < old_len)
				{
					pool.cond_task_acquired.broadcast();
					if (remain_tasks.len == 0) continue OUT;
				}
				pool.cond_task_finished.wait(&pool.mutex);
			}
		}
		else
		{
			pool = &self.low_pool;
			remain_tasks = pack.tasks;
			pool.mutex.lock();
			defer pool.mutex.unlock();

			while (remain_tasks.len)
			{
				old_len = remain_tasks.len;
				remain_tasks = self.low_queue.push_all_safe(remain_tasks);
				if (remain_tasks.len < old_len)
				{
					pool.cond_task_acquired.broadcast();
					if (remain_tasks.len == 0) continue OUT;
				}
				pool.cond_task_finished.wait(&pool.mutex);
			}
		}
	}
}

<*
 Internal procedure for running high-priority threads.
*>
fn int process_high_prio_task(void* arg) @local
{
	ThreadCreateData* thread_data = arg;
	sz thread_idx                 = thread_data.idx;
	ThreadPoolPrio* self          = thread_data.tpool;
	PoolData* pool                = &self.high_pool;
	sz temp_pool_mem_amount       = thread_data.temp_pool_mem_amount;

	mem = thread_data.mem;
	tmem = thread_data.tmem;

	@pool_init(tmem, temp_pool_mem_amount)
	{
		while (true)
		{
			pool.mutex.lock();
			// Wait for work.
			while (self.high_queue.is_empty())
			{
				if (pool.stop)
				{
					// Shutdown requested.
					pool.alive_thread_count--;
					pool.mutex.unlock();
					return 0;
				}

				self.high_threads_working[thread_idx] = false;
				pool.cond_task_acquired.wait(&pool.mutex);

				if (pool.stop_now)
				{
					// Shutdown requested.
					pool.alive_thread_count--;
					pool.mutex.unlock();
					return 0;
				}
			}
			ThreadTask task = self.high_queue.pop_first_ensure();
			self.high_threads_working[thread_idx] = true;
			pool.mutex.unlock();
			// Process the task.
			task.func(task.arg);
			pool.cond_task_finished.broadcast();
		}
	};
}

<*
 Internal procedure for running low-priority threads.
*>
fn int process_low_prio_task(void* arg) @local
{
	ThreadCreateData* thread_data = arg;
	sz thread_idx                 = thread_data.idx;
	ThreadPoolPrio* self          = thread_data.tpool;
	PoolData* pool                = &self.low_pool;
	sz temp_pool_mem_amount       = thread_data.temp_pool_mem_amount;

	mem = thread_data.mem;
	tmem = thread_data.tmem;

	@pool_init(tmem, temp_pool_mem_amount)
	{
		while (true)
		{
			pool.mutex.lock();
			// Wait for work.
			while (self.low_queue.is_empty())
			{
				if (pool.stop)
				{
					// Shutdown requested.
					pool.alive_thread_count--;
					pool.mutex.unlock();
					return 0;
				}

				self.low_threads_working[thread_idx] = false;
				pool.cond_task_acquired.wait(&pool.mutex);

				if (pool.stop_now)
				{
					// Shutdown requested.
					pool.alive_thread_count--;
					pool.mutex.unlock();
					return 0;
				}
			}
			ThreadTask task = self.low_queue.pop_first_ensure();
			self.low_threads_working[thread_idx] = true;
			pool.mutex.unlock();
			// Process the task.
			task.func(task.arg);
			pool.cond_task_finished.broadcast();
		}
	};
}

<*
 Stop all the threads and cleanup the pool.
 Any pending work will be dropped.
*>
fn void ThreadPoolPrio.destroy(&self)
{
	@shutdown(self, &self.high_pool, self.high_pool.stop_now);
	@shutdown(self, &self.low_pool, self.low_pool.stop_now);
}

<*
 Stop all the threads and cleanup the pool.
 Any pending work will be processed.
*>
fn void ThreadPoolPrio.stop_and_destroy(&self)
{
	@shutdown(self, &self.high_pool, self.high_pool.stop);
	@shutdown(self, &self.low_pool, self.low_pool.stop);
}

macro void @shutdown(ThreadPoolPrio* self, PoolData* pool, bool #stop) @local
{
	if (pool.initialized)
	{
		pool.mutex.lock();
		#stop = true;
		pool.cond_task_acquired.broadcast();
		pool.mutex.unlock();
		// Wait for all threads to shutdown.
		while (true)
		{
			pool.mutex.lock();
			defer pool.mutex.unlock();
			if (!high_threads_idle(self) && !low_threads_idle(self))
			{
				break;
			}
			pool.cond_task_acquired.signal();
		}
		pool.mutex.destroy();
		pool.cond_task_acquired.destroy();
		pool.cond_task_finished.destroy();
		pool.cond_collect.destroy();
		pool.initialized = false;
	}
}

<*
 Tells if subpools are initialized.
*>
fn bool ThreadPoolPrio.is_initialized(&self)
{
	return self.high_pool.initialized && self.low_pool.initialized;
}

macro sz low_threads_idle(ThreadPoolPrio* self) @local
{
	return LOW_THREADS - self.low_threads_working.set_count();
}

macro sz low_threads_working(ThreadPoolPrio* self) @local
{
	return self.low_threads_working.set_count();
}

macro sz high_threads_idle(ThreadPoolPrio* self) @local
{
	return HIGH_THREADS - self.high_threads_working.set_count();
}

macro sz high_threads_working(ThreadPoolPrio* self) @local
{
	return self.high_threads_working.set_count();
}
