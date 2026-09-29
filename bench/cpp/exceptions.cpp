#include "_harness.hpp"
#include <stdexcept>
#include <cstdint>

struct MyError : std::runtime_error {
    MyError() : std::runtime_error("boom") {}
};

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        int64_t total = 0;
        for (int i = 0; i < 20000; i++) {
            try {
                throw MyError();
            } catch (const MyError&) {
                total += 1;
            }
        }
        sink = total;
    });
}
