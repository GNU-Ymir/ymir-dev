#include "_pool.hpp"
#include <chrono>

// A leaf a task parks on until a thread outside the pool opens it.
class Gate {
public:
    bool await_ready() { return false; }
    bool await_suspend(std::coroutine_handle<> h) {
        std::lock_guard g(lock);
        if (opened) return false;
        current_task->resume_point = h;
        waker = current_task;
        return true;
    }
    void await_resume() {}

    void open() {
        Task* w;
        {
            std::lock_guard g(lock);
            opened = true;
            w = std::exchange(waker, nullptr);
        }
        if (w) w->wake();
    }

    bool parked() {
        std::lock_guard g(lock);
        return waker != nullptr;
    }

private:
    std::mutex lock;
    bool opened = false;
    Task* waker = nullptr;
};

static Async<void> parked(Gate& g) { co_await g; }

static double cpu_ms(const rusage& r) {
    return (r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1e3 + (r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e3;
}

// Submits a task per gate, and returns once every one of them is parked.
static std::vector<std::unique_ptr<Gate>> park(TaskPool& pool, uint64_t tasks) {
    std::vector<std::unique_ptr<Gate>> gates;
    for (uint64_t t = 0; t < tasks; t++) {
        gates.push_back(std::make_unique<Gate>());
        pool.submit(parked(*gates.back()));
    }
    for (auto& g : gates)
        while (!g->parked()) std::this_thread::sleep_for(std::chrono::microseconds(100));
    return gates;
}

int main() {
    const uint64_t tasks = 10000;
    TaskPool pool(4);
    auto wake = [&](std::vector<std::unique_ptr<Gate>>& gates) {
        for (auto& g : gates) g->open();
        pool.join();
    };

    for (int i = 0; i < 23; i++) {
        auto gates = park(pool, tasks);
        auto t0 = std::chrono::high_resolution_clock::now();
        wake(gates);
        auto t1 = std::chrono::high_resolution_clock::now();
        if (i >= 2) printf("%.6f\n", std::chrono::duration<double, std::milli>(t1 - t0).count());
    }

    auto gates = park(pool, tasks);
    rusage before, after;
    getrusage(RUSAGE_SELF, &before);
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    getrusage(RUSAGE_SELF, &after);
    printf("metric parked_cpu_ms %f\n", cpu_ms(after) - cpu_ms(before));
    wake(gates);

    measure([&] {
        auto gates = park(pool, tasks);
        wake(gates);
    }, tasks);
}
