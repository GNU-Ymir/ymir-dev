#include "_harness.hpp"
#include <vector>
#include <thread>
#include <cstdint>

int main() {
    const int64_t n = 2000000;
    std::vector<int64_t> data(n);
    for (int64_t i = 0; i < n; i++) data[i] = i;

    volatile int64_t sink;
    run_bench([&]() {
        int64_t partial[4] = {0, 0, 0, 0};
        std::thread threads[4];
        int64_t chunk = n / 4;
        for (int t = 0; t < 4; t++) {
            threads[t] = std::thread([&, t]() {
                int64_t lo = t * chunk, hi = lo + chunk;
                int64_t s = 0;
                for (int64_t i = lo; i < hi; i++) s += data[i];
                partial[t] = s;
            });
        }
        for (auto& th : threads) th.join();
        sink = partial[0] + partial[1] + partial[2] + partial[3];
    });
}
