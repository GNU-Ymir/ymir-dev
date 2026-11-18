#pragma once
#include <atomic>
#include <condition_variable>
#include <coroutine>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>
#include <semaphore.h>
#include <sys/resource.h>

// Every heap allocation of the program is counted, the counterpart of the GC bytes of Ymir.
inline std::atomic<uint64_t> allocated_bytes{0};

void* operator new(std::size_t n) {
    allocated_bytes.fetch_add(n, std::memory_order_relaxed);
    if (void* p = std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }

class TaskPool;

// A POSIX semaphore, the one the Ymir Semaphore wraps: std::counting_semaphore spins before it sleeps.
class Semaphore {
public:
    Semaphore() { sem_init(&sem, 0, 0); }
    ~Semaphore() { sem_destroy(&sem); }
    void release() { sem_post(&sem); }
    void acquire() {
        while (sem_wait(&sem) != 0) {}
    }

private:
    sem_t sem;
};

// A coroutine and its scheduling state, the counterpart of std::concurrency::Task: `wake` is its waker, `run` its
// poll, resuming the innermost frame of the coroutine, where it last suspended.
class Task {
public:
    enum State { IDLE, SCHEDULED, RUNNING, NOTIFIED, DONE };

    Task(std::coroutine_handle<> root, TaskPool* pool) : resume_point(root), root(root), pool(pool) {}
    ~Task() { root.destroy(); }

    void wake();
    bool run();

    std::coroutine_handle<> resume_point;
    bool completed = false;

private:
    std::mutex lock;
    State state = SCHEDULED;
    std::coroutine_handle<> root;
    TaskPool* pool;
};

// The task the calling worker is polling, the one a leaf registers as waker.
inline thread_local Task* current_task = nullptr;

struct Unit {};

template <typename T>
class Async;

struct AsyncPromiseBase {
    std::coroutine_handle<> continuation;

    struct Final {
        bool await_ready() noexcept { return false; }
        template <typename P>
        std::coroutine_handle<> await_suspend(std::coroutine_handle<P> h) noexcept {
            auto c = h.promise().continuation;
            if (c) {
                current_task->resume_point = c;
                return c;
            }
            current_task->completed = true;
            return std::noop_coroutine();
        }
        void await_resume() noexcept {}
    };

    std::suspend_always initial_suspend() noexcept { return {}; }
    Final final_suspend() noexcept { return {}; }
    void unhandled_exception() { std::abort(); }
};

template <typename T>
struct AsyncPromise : AsyncPromiseBase {
    std::optional<T> value;
    Async<T> get_return_object();
    void return_value(T v) { value = std::move(v); }
    T result() { return std::move(*value); }
};

template <>
struct AsyncPromise<void> : AsyncPromiseBase {
    Async<void> get_return_object();
    void return_void() {}
    void result() {}
};

// A lazy coroutine, the counterpart of `async-> T`: awaiting it from another one resumes it in place.
template <typename T>
class Async {
public:
    using promise_type = AsyncPromise<T>;
    using handle = std::coroutine_handle<promise_type>;

    explicit Async(handle h) : frame(h) {}
    Async(Async&& o) noexcept : frame(std::exchange(o.frame, {})) {}
    ~Async() {
        if (frame) frame.destroy();
    }

    handle release() { return std::exchange(frame, {}); }

    bool await_ready() { return false; }
    std::coroutine_handle<> await_suspend(std::coroutine_handle<> h) {
        frame.promise().continuation = h;
        current_task->resume_point = frame;
        return frame;
    }
    T await_resume() { return frame.promise().result(); }

private:
    handle frame;
};

template <typename T>
Async<T> AsyncPromise<T>::get_return_object() {
    return Async<T>(Async<T>::handle::from_promise(*this));
}
inline Async<void> AsyncPromise<void>::get_return_object() {
    return Async<void>(Async<void>::handle::from_promise(*this));
}

// A bare `await;`: the task wakes itself during the poll, and is requeued at the back of the ready queue.
struct Yield {
    bool await_ready() { return false; }
    void await_suspend(std::coroutine_handle<> h) {
        current_task->resume_point = h;
        current_task->wake();
    }
    void await_resume() {}
};

// The result of a submitted coroutine, the counterpart of TaskHandle: awaited from a task, waited on from a thread.
template <typename T>
class Handle {
public:
    void complete(T v) {
        std::vector<Task*> w;
        {
            std::lock_guard g(lock);
            value = std::move(v);
            w.swap(wakers);
        }
        done.notify_all();
        for (Task* t : w) t->wake();
    }

    T wait() {
        std::unique_lock g(lock);
        done.wait(g, [this] { return value.has_value(); });
        return *value;
    }

    bool await_ready() { return false; }
    bool await_suspend(std::coroutine_handle<> h) {
        std::lock_guard g(lock);
        if (value) return false;
        current_task->resume_point = h;
        for (Task* t : wakers)
            if (t == current_task) return true;
        wakers.push_back(current_task);
        return true;
    }
    T await_resume() {
        std::lock_guard g(lock);
        return *value;
    }

private:
    std::mutex lock;
    std::condition_variable done;
    std::optional<T> value;
    std::vector<Task*> wakers;
};

template <typename T>
using result_t = std::conditional_t<std::is_void_v<T>, Unit, T>;

template <typename T>
Async<void> drive(std::shared_ptr<Handle<result_t<T>>> h, Async<T> source) {
    if constexpr (std::is_void_v<T>) {
        co_await std::move(source);
        h->complete(Unit{});
    } else {
        h->complete(co_await std::move(source));
    }
}

// The counterpart of AsyncMailBox: a send wakes the receiver waiting the longest. The message is handed to it
// under the lock, since a resumed coroutine cannot suspend again from `await_resume` to retry the take.
template <typename T>
class AsyncMailBox {
public:
    struct Receive {
        AsyncMailBox* box;
        std::optional<T> value;
        Task* task = nullptr;

        bool await_ready() { return false; }
        bool await_suspend(std::coroutine_handle<> h) {
            std::lock_guard g(box->lock);
            if (!box->mails.empty()) {
                value = std::move(box->mails.front());
                box->mails.pop_front();
                return false;
            }
            task = current_task;
            task->resume_point = h;
            box->waiting.push_back(this);
            return true;
        }
        std::optional<T> await_resume() { return std::move(value); }
    };

    void send(T v) {
        Receive* r = nullptr;
        {
            std::lock_guard g(lock);
            if (waiting.empty()) {
                mails.push_back(std::move(v));
            } else {
                r = waiting.front();
                waiting.pop_front();
                r->value = std::move(v);
            }
        }
        if (r) r->task->wake();
    }

    Receive receive() { return Receive{this}; }

private:
    std::mutex lock;
    std::deque<T> mails;
    std::deque<Receive*> waiting;
};

// The counterpart of the Ymir TaskPool: one FIFO of ready tasks under a mutex, a semaphore counting them, workers
// polling a task once each time they dequeue it.
class TaskPool {
public:
    explicit TaskPool(unsigned n) {
        for (unsigned i = 0; i < n; i++) threads.emplace_back([this] { worker(); });
    }

    ~TaskPool() {
        {
            std::lock_guard g(lock);
            terminated = true;
        }
        for (size_t i = 0; i < threads.size(); i++) wait_task.release();
        for (auto& t : threads) t.join();
        for (Task* t : queue) delete t;
    }

    template <typename T>
    std::shared_ptr<Handle<result_t<T>>> submit(Async<T> value) {
        auto h = std::make_shared<Handle<result_t<T>>>();
        Task* task = new Task(drive<T>(h, std::move(value)).release(), this);
        {
            std::lock_guard g(lock);
            submitted++;
        }
        schedule(task);
        return h;
    }

    void join() {
        for (;;) {
            {
                std::lock_guard g(lock);
                if (terminated || finished == submitted) return;
            }
            ready.acquire();
        }
    }

    void schedule(Task* t) {
        {
            std::lock_guard g(lock);
            if (terminated) return;
            queue.push_back(t);
        }
        wait_task.release();
    }

private:
    void worker() {
        for (;;) {
            wait_task.acquire();
            Task* t;
            {
                std::lock_guard g(lock);
                if (terminated) return;
                if (queue.empty()) continue;
                t = queue.front();
                queue.pop_front();
            }
            if (t->run()) {
                delete t;
                std::lock_guard g(lock);
                if (++finished == submitted) ready.release();
            }
        }
    }

    std::mutex lock;
    std::deque<Task*> queue;
    Semaphore wait_task, ready;
    std::vector<std::thread> threads;
    uint64_t submitted = 0, finished = 0;
    bool terminated = false;
};

inline void Task::wake() {
    bool push = false;
    {
        std::lock_guard g(lock);
        if (state == IDLE) {
            state = SCHEDULED;
            push = true;
        } else if (state == RUNNING) {
            state = NOTIFIED;
        }
    }
    if (push) pool->schedule(this);
}

inline bool Task::run() {
    {
        std::lock_guard g(lock);
        if (state != SCHEDULED) return state == DONE;
        state = RUNNING;
    }
    Task* outer = std::exchange(current_task, this);
    resume_point.resume();
    current_task = outer;

    bool push = false, done = completed;
    {
        std::lock_guard g(lock);
        if (done) {
            state = DONE;
        } else if (state == NOTIFIED) {
            state = SCHEDULED;
            push = true;
        } else {
            state = IDLE;
        }
    }
    if (push) pool->schedule(this);
    return done;
}

// Prints the heap bytes allocated per `unit` and the context switches of one more, untimed, run.
template <typename F>
void measure(F fn, uint64_t count, const char* unit = "task") {
    rusage before, after;
    uint64_t bytes = allocated_bytes.load();
    getrusage(RUSAGE_SELF, &before);
    fn();
    getrusage(RUSAGE_SELF, &after);
    uint64_t allocated = allocated_bytes.load() - bytes;
    printf("metric bytes_per_%s %f\n", unit, double(allocated) / double(count));
    printf("metric voluntary_switches %ld\n", after.ru_nvcsw - before.ru_nvcsw);
    printf("metric involuntary_switches %ld\n", after.ru_nivcsw - before.ru_nivcsw);
}
