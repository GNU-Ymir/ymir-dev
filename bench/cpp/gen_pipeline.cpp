#include "_harness.hpp"
#include <cstdint>
#include <ranges>

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        auto v = std::views::iota(int64_t(0), int64_t(10000000))
               | std::views::transform([](int64_t x) { return x * 3; })
               | std::views::filter([](int64_t x) { return x % 2 == 0; });
        int64_t total = 0;
        for (int64_t x : v) total += x;
        sink = total;
    });
}
