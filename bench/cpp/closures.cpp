#include "_harness.hpp"
#include <vector>
#include <cstdint>

int main() {
    const int64_t n = 500000;
    std::vector<int64_t> data(n);
    for (int64_t i = 0; i < n; i++) data[i] = i;

    volatile int64_t sink;
    run_bench([&]() {
        auto f = [](int64_t x) { return x * x + 1; };
        int64_t total = 0;
        for (int64_t v : data) total += f(v);
        sink = total;
    });
}
