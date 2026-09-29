#include "_harness.hpp"
#include <vector>
#include <memory>
#include <cstdint>

struct Base {
    virtual int value() const { return 0; }
    virtual ~Base() = default;
};
struct A : Base { int value() const override { return 1; } };
struct B : Base { int value() const override { return 2; } };

int main() {
    std::vector<std::unique_ptr<Base>> objs;
    for (int i = 0; i < 1000; i++) {
        if (i % 2 == 0) objs.push_back(std::make_unique<A>());
        else objs.push_back(std::make_unique<B>());
    }

    volatile int64_t sink;
    run_bench([&]() {
        int64_t total = 0;
        for (int i = 0; i < 1000; i++) {
            for (auto& o : objs) total += o->value();
        }
        sink = total;
    });
}
