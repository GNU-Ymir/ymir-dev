#pragma once
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <mutex>
#include <new>
#include <thread>
#include <vector>
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

// A FIFO of std::function shared by its workers under one mutex, the pool the Ymir TaskPool is.
class TaskPool {
    std::mutex lock;
    std::condition_variable ready, done;
    std::deque<std::function<void()>> tasks;
    std::vector<std::thread> threads;
    uint64_t submitted = 0, finished = 0;
    bool stop = false;

public:
    explicit TaskPool(unsigned n) {
        for (unsigned i = 0; i < n; i++) threads.emplace_back([this] { worker(); });
    }

    ~TaskPool() {
        {
            std::lock_guard g(lock);
            stop = true;
        }
        ready.notify_all();
        for (auto& t : threads) t.join();
    }

    void submit(std::function<void()> task) {
        {
            std::lock_guard g(lock);
            submitted++;
            tasks.push_back(std::move(task));
        }
        ready.notify_one();
    }

    void join() {
        std::unique_lock g(lock);
        done.wait(g, [this] { return finished == submitted; });
    }

private:
    void worker() {
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock g(lock);
                ready.wait(g, [this] { return stop || !tasks.empty(); });
                if (tasks.empty()) return;
                task = std::move(tasks.front());
                tasks.pop_front();
            }
            task();
            std::lock_guard g(lock);
            if (++finished == submitted) done.notify_all();
        }
    }
};

// Prints the heap bytes allocated per task and the context switches of one more, untimed, run.
template <typename F>
void measure(F fn, uint64_t tasks) {
    rusage before, after;
    uint64_t bytes = allocated_bytes.load();
    getrusage(RUSAGE_SELF, &before);
    fn();
    getrusage(RUSAGE_SELF, &after);
    uint64_t allocated = allocated_bytes.load() - bytes;
    printf("metric bytes_per_task %f\n", double(allocated) / double(tasks));
    printf("metric voluntary_switches %ld\n", after.ru_nvcsw - before.ru_nvcsw);
    printf("metric involuntary_switches %ld\n", after.ru_nivcsw - before.ru_nivcsw);
}
