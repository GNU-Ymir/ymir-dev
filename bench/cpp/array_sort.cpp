#include "_harness.hpp"
#include <vector>
#include <algorithm>
#include <cstdint>

static std::vector<int64_t> lcg_array(int64_t n, uint64_t seed = 12345) {
    std::vector<int64_t> a(n);
    uint64_t x = seed;
    for (int64_t i = 0; i < n; i++) {
        x = x * 6364136223846793005ULL + 1442695040888963407ULL;
        a[i] = (int64_t)(x % 1000000ULL);
    }
    return a;
}

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        auto a = lcg_array(50000);
        std::sort(a.begin(), a.end());
        sink = a[0];
    });
}
