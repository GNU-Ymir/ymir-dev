#include "_harness.hpp"
#include "_pool.hpp"

static Async<void> yielder(uint64_t n) {
    for (uint64_t i = 0; i < n; i++) co_await Yield{};
}

int main() {
    const uint64_t tasks = 1000, yields = 1000;
    TaskPool pool(4);
    auto f = [&]() {
        for (uint64_t t = 0; t < tasks; t++) pool.submit(yielder(yields));
        pool.join();
    };
    run_bench(f);
    measure(f, tasks * yields, "yield");
}
