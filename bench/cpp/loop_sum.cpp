#include "_harness.hpp"
#include <cstdint>

int main() {
    volatile uint64_t sink;
    run_bench([&]() {
        uint64_t s = 0;
        for (uint64_t i = 0; i < 2000000; i++) {
            s = (s ^ i) * 2654435761ULL;
        }
        sink = s;
    });
}
