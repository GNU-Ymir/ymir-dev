#include "_harness.hpp"
#include "_coro.hpp"
#include <cstdint>

generator<int64_t> small(int64_t seed) {
    co_yield seed;
    co_yield seed + 1;
    co_yield seed + 2;
}

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        int64_t total = 0;
        for (int64_t i = 0; i < 1000000; i++) {
            auto g = small(i);
            int64_t v;
            if (g.next(v)) total += v;
            if (g.next(v)) total += v;
        }
        sink = total;
    });
}
