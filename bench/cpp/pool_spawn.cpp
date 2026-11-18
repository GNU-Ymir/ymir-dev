#include "_harness.hpp"
#include "_pool.hpp"

static void empty_task() {}

int main() {
    const uint64_t tasks = 1000000;
    TaskPool pool(4);
    auto f = [&]() {
        for (uint64_t t = 0; t < tasks; t++) pool.submit([] { empty_task(); });
        pool.join();
    };
    run_bench(f);
    measure(f, tasks);
}
