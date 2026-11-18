#include "_harness.hpp"
#include "_pool.hpp"

static void empty_task() {}

static Async<void> spawned() {
    empty_task();
    co_return;
}

int main() {
    const uint64_t tasks = 1000000;
    TaskPool pool(4);
    auto f = [&]() {
        for (uint64_t t = 0; t < tasks; t++) pool.submit(spawned());
        pool.join();
    };
    run_bench(f);
    measure(f, tasks);
}
