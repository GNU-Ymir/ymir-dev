#include "_harness.hpp"
#include "_coro.hpp"
#include <cstdint>

task<int64_t> a0(int64_t x) { co_return x + 1; }
task<int64_t> a1(int64_t x) { co_return (co_await a0(x)) + 1; }
task<int64_t> a2(int64_t x) { co_return (co_await a1(x)) + 1; }
task<int64_t> a3(int64_t x) { co_return (co_await a2(x)) + 1; }
task<int64_t> a4(int64_t x) { co_return (co_await a3(x)) + 1; }
task<int64_t> a5(int64_t x) { co_return (co_await a4(x)) + 1; }
task<int64_t> a6(int64_t x) { co_return (co_await a5(x)) + 1; }
task<int64_t> a7(int64_t x) { co_return (co_await a6(x)) + 1; }
task<int64_t> a8(int64_t x) { co_return (co_await a7(x)) + 1; }
task<int64_t> a9(int64_t x) { co_return (co_await a8(x)) + 1; }
task<int64_t> a10(int64_t x) { co_return (co_await a9(x)) + 1; }

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        int64_t total = 0;
        for (int64_t i = 0; i < 100000; i++) total += a10(i).run();
        sink = total;
    });
}
