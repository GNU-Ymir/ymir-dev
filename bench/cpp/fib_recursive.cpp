#include "_harness.hpp"
#include <cstdint>

static int64_t fib(int64_t n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        sink = fib(27);
    });
}
