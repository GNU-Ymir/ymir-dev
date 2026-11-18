#include "_harness.hpp"
#include "_pool.hpp"

static Async<uint64_t> child(uint64_t i) { co_return i; }

static Async<uint64_t> root(TaskPool& pool, uint64_t n) {
    std::vector<std::shared_ptr<Handle<uint64_t>>> handles;
    handles.reserve(n);
    for (uint64_t i = 0; i < n; i++) handles.push_back(pool.submit(child(i)));
    uint64_t total = 0;
    for (auto& h : handles) total += co_await *h;
    co_return total;
}

int main() {
    const uint64_t children = 100000;
    TaskPool pool(4);
    auto f = [&]() {
        uint64_t total = pool.submit(root(pool, children))->wait();
        pool.join();
        if (total != children * (children - 1) / 2) fprintf(stderr, "wrong total: %lu\n", total);
    };
    run_bench(f);
    measure(f, children);
}
