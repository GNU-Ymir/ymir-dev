#pragma once
#include <algorithm>
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
// poll, resuming the innermost frame of the coroutine, where it last suspended. The state is a lock-free word, each
// transition a compare-and-swap.
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
    std::atomic<uint32_t> state{SCHEDULED};
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

// The ready tasks of a worker: a FIFO the other workers steal from, under the lock of the worker, aligned on a cache
// line as the Ymir monitors are.
struct alignas(64) Worker {
    TaskPool* pool;
    size_t index;
    std::mutex lock;
    std::deque<Task*> queue;
    std::atomic<uint32_t> filled{0};  // 1 iif the queue holds a task, read without the lock by the searching workers
    std::deque<Task*> taken;          // the tasks taken from another queue, used by the thread of the worker alone
    Semaphore wakeup;
    uint32_t seed;

    Worker(TaskPool* pool, size_t index) : pool(pool), index(index), seed(uint32_t(index) * 2654435761u + 1u) {}

    void push(Task* t) {
        std::lock_guard g(lock);
        queue.push_back(t);
        if (queue.size() == 1) filled.store(1, std::memory_order_release);
    }

    Task* next() {
        std::lock_guard g(lock);
        if (queue.empty()) return nullptr;
        Task* t = queue.front();
        queue.pop_front();
        if (queue.empty()) filled.store(0, std::memory_order_release);
        return t;
    }

    bool looks_empty() const { return filled.load(std::memory_order_acquire) == 0; }

    // Takes the front half of the queue of `victim`, rounded up.
    size_t steal(Worker& victim) {
        std::lock_guard g(victim.lock);
        size_t n = victim.queue.size() - victim.queue.size() / 2;
        for (size_t i = 0; i < n; i++) {
            taken.push_back(victim.queue.front());
            victim.queue.pop_front();
        }
        if (victim.queue.empty()) victim.filled.store(0, std::memory_order_release);
        return n;
    }

    // The first of the tasks taken, the others going to the back of the queue.
    Task* adopt() {
        if (taken.empty()) return nullptr;
        Task* first = taken.front();
        taken.pop_front();
        if (!taken.empty()) {
            std::lock_guard g(lock);
            while (!taken.empty()) {
                queue.push_back(taken.front());
                taken.pop_front();
            }
            filled.store(1, std::memory_order_release);
        }
        return first;
    }

    size_t random(size_t nb) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        return seed % nb;
    }
};

// The worker running on the calling thread.
inline thread_local Worker* current_worker = nullptr;

// The sleeping workers, in the order they fell asleep.
class Sleepers {
public:
    explicit Sleepers(size_t nb) : asleep(nb, false) {}

    void add(size_t i) {
        std::lock_guard g(lock);
        asleep[i] = true;
        order.push_back(i);
        count.store(count.load(std::memory_order_relaxed) + 1, std::memory_order_release);
    }

    // False if `pop` already took the worker out, its semaphore being posted.
    bool remove(size_t i) {
        std::lock_guard g(lock);
        if (!asleep[i]) return false;
        asleep[i] = false;
        for (auto it = order.begin(); it != order.end(); ++it)
            if (*it == i) {
                order.erase(it);
                break;
            }
        count.store(count.load(std::memory_order_relaxed) - 1, std::memory_order_release);
        return true;
    }

    std::optional<size_t> pop() {
        std::lock_guard g(lock);
        if (order.empty()) return std::nullopt;
        size_t i = order.front();
        order.pop_front();
        asleep[i] = false;
        count.store(count.load(std::memory_order_relaxed) - 1, std::memory_order_release);
        return i;
    }

    uint32_t size() const { return count.load(std::memory_order_acquire); }

private:
    std::mutex lock;
    std::vector<bool> asleep;
    std::deque<size_t> order;
    std::atomic<uint32_t> count{0};
};

// The counterpart of the Ymir TaskPool: a queue per worker and one for the tasks scheduled from outside, a worker
// out of tasks stealing half of another's queue, searching the queues a few rounds before it sleeps on a semaphore
// of its own, and a schedule waking a sleeping worker only while none is searching.
class TaskPool {
public:
    static constexpr uint32_t INJECT_EVERY = 61;
    static constexpr size_t INJECT_BATCH = 32;
    static constexpr uint32_t SEARCH_ROUNDS = 64;

    explicit TaskPool(unsigned n) : nb_threads(n), sleepers(n) {
        for (unsigned i = 0; i < n; i++) workers.push_back(std::make_unique<Worker>(this, i));
        for (unsigned i = 0; i < n; i++) threads.emplace_back([this, i] { worker_main(*workers[i]); });
    }

    ~TaskPool() {
        {
            std::lock_guard g(lock);
            terminated.store(true, std::memory_order_release);
            for (Task* t : inject) delete t;
            inject.clear();
        }
        for (auto& w : workers) w->wakeup.release();
        for (auto& t : threads) t.join();
        for (auto& w : workers)
            for (Task* t : w->queue) delete t;
    }

    template <typename T>
    std::shared_ptr<Handle<result_t<T>>> submit(Async<T> value) {
        auto h = std::make_shared<Handle<result_t<T>>>();
        Task* task = new Task(drive<T>(h, std::move(value)).release(), this);
        submitted.fetch_add(1, std::memory_order_acq_rel);
        schedule(task);
        return h;
    }

    void join() {
        for (;;) {
            if (terminated.load(std::memory_order_acquire)) return;
            uint64_t f = finished.load(std::memory_order_acquire);
            if (f == submitted.load(std::memory_order_acquire)) return;
            ready.acquire();
        }
    }

    void schedule(Task* t) {
        Worker* w = current_worker;
        if (w && w->pool == this) {
            if (terminated.load(std::memory_order_acquire)) return;
            w->push(t);
        } else {
            std::lock_guard g(lock);
            if (terminated.load(std::memory_order_acquire)) return;
            inject.push_back(t);
            if (inject.size() == 1) inject_filled.store(1, std::memory_order_release);
        }
        notify();
    }

private:
    void notify() {
        if (searching.load(std::memory_order_acquire) != 0) return;
        if (sleepers.size() == 0) return;
        if (auto i = sleepers.pop()) {
            searching.fetch_add(1, std::memory_order_acq_rel);
            workers[*i]->wakeup.release();
        }
    }

    bool start_searching() {
        uint32_t nb = searching.load(std::memory_order_acquire);
        while (2 * nb < nb_threads)
            if (searching.compare_exchange_weak(nb, nb + 1, std::memory_order_acq_rel)) return true;
        return false;
    }

    // True iif the caller was the last searching worker.
    bool stop_searching() { return searching.fetch_sub(1, std::memory_order_acq_rel) == 1; }

    void finish() {
        if (finished.fetch_add(1, std::memory_order_acq_rel) + 1 == submitted.load(std::memory_order_acquire))
            ready.release();
    }

    size_t take_injected(Worker& w, size_t max) {
        std::lock_guard g(lock);
        if (inject.empty()) return 0;
        size_t n = std::min({inject.size() / workers.size() + 1, inject.size(), max});
        for (size_t i = 0; i < n; i++) {
            w.taken.push_back(inject.front());
            inject.pop_front();
        }
        if (inject.empty()) inject_filled.store(0, std::memory_order_release);
        return n;
    }

    size_t steal(Worker& w, bool hinted) {
        size_t nb = workers.size();
        if (nb < 2) return 0;
        size_t start = w.random(nb);
        for (size_t k = 0; k < nb; k++) {
            size_t i = (start + k) % nb;
            if (i != w.index && !(hinted && workers[i]->looks_empty()))
                if (size_t n = w.steal(*workers[i])) return n;
        }
        return 0;
    }

    Task* adopt(Worker& w, size_t nb) {
        Task* t = w.adopt();
        if (nb > 1) notify();
        return t;
    }

    Task* local(Worker& w, bool fair) {
        if (fair)
            if (size_t n = take_injected(w, 1)) return adopt(w, n);
        return w.next();
    }

    Task* foreign(Worker& w, bool hinted) {
        if (!(hinted && inject_filled.load(std::memory_order_acquire) == 0))
            if (size_t n = take_injected(w, INJECT_BATCH)) return adopt(w, n);
        if (size_t s = steal(w, hinted)) return adopt(w, s);
        return nullptr;
    }

    Task* search(Worker& w) {
        for (uint32_t r = 0; r < SEARCH_ROUNDS; r++) {
            if (Task* t = foreign(w, true)) return t;
            if (terminated.load(std::memory_order_acquire)) return nullptr;
        }
        return nullptr;
    }

    // Counts `w` asleep and uncounts it searching, then looks at every queue under its lock once more before sleeping.
    Task* park(Worker& w, bool& is_searching) {
        sleepers.add(w.index);
        bool last = is_searching && stop_searching();
        is_searching = false;

        Task* found = w.next();
        if (!found) found = foreign(w, false);
        if (found) {
            if (!sleepers.remove(w.index)) {
                w.wakeup.acquire();
                is_searching = true;
            } else if (last) {
                notify();
            }
            return found;
        }

        w.wakeup.acquire();
        is_searching = true;
        return nullptr;
    }

    void worker_main(Worker& w) {
        current_worker = &w;
        uint32_t ticks = 0;
        bool is_searching = false;
        while (!terminated.load(std::memory_order_acquire)) {
            ticks++;
            Task* t = local(w, ticks % INJECT_EVERY == 0);
            if (!t) {
                if (!is_searching) is_searching = start_searching();
                if (is_searching) t = search(w);
                if (!t) t = park(w, is_searching);
            }
            if (t) {
                if (is_searching) {
                    is_searching = false;
                    if (stop_searching()) notify();
                }
                if (t->run()) {
                    delete t;
                    finish();
                }
            }
        }
        current_worker = nullptr;
    }

    const uint32_t nb_threads;
    std::mutex lock;
    std::deque<Task*> inject;
    std::atomic<uint32_t> inject_filled{0};
    std::vector<std::unique_ptr<Worker>> workers;
    Sleepers sleepers;
    std::atomic<uint32_t> searching{0};
    Semaphore ready;
    std::vector<std::thread> threads;
    std::atomic<uint64_t> submitted{0}, finished{0};
    std::atomic<bool> terminated{false};
};

inline void Task::wake() {
    uint32_t cur = IDLE;
    for (;;) {
        if (cur == IDLE) {
            if (state.compare_exchange_weak(cur, SCHEDULED, std::memory_order_acq_rel)) {
                pool->schedule(this);
                return;
            }
        } else if (cur == RUNNING) {
            if (state.compare_exchange_weak(cur, NOTIFIED, std::memory_order_acq_rel)) return;
        } else {
            return;
        }
    }
}

inline bool Task::run() {
    uint32_t cur = SCHEDULED;
    if (!state.compare_exchange_strong(cur, RUNNING, std::memory_order_acq_rel)) return cur == DONE;

    Task* outer = std::exchange(current_task, this);
    resume_point.resume();
    current_task = outer;

    if (completed) {
        state.store(DONE, std::memory_order_release);
        return true;
    }
    cur = RUNNING;
    if (!state.compare_exchange_strong(cur, IDLE, std::memory_order_acq_rel)) {
        state.store(SCHEDULED, std::memory_order_release);  // NOTIFIED, a state only the polling thread leaves
        pool->schedule(this);
    }
    return false;
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
