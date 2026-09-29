#include "_harness.hpp"
#include <vector>
#include <cstdint>

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        const int64_t n = 500000;
        std::vector<int64_t> a(n);
        for (int64_t i = 0; i < n; i++) a[i] = i * 2;
        int64_t s = 0;
        for (int64_t v : a) s += v;
        sink = s;
    });
}
