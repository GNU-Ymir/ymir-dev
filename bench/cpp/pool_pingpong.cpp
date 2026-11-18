#include "_harness.hpp"
#include "_pool.hpp"

static Async<void> ping(AsyncMailBox<uint64_t>& out, AsyncMailBox<uint64_t>& in, uint64_t n) {
    for (uint64_t i = 0; i < n; i++) {
        out.send(i);
        co_await in.receive();
    }
}

static Async<void> pong(AsyncMailBox<uint64_t>& in, AsyncMailBox<uint64_t>& out, uint64_t n) {
    for (uint64_t i = 0; i < n; i++) {
        auto v = co_await in.receive();
        out.send(*v);
    }
}

int main() {
    const uint64_t pairs = 4, rounds = 50000;
    TaskPool pool(4);
    auto f = [&]() {
        std::vector<std::unique_ptr<AsyncMailBox<uint64_t>>> boxes;
        for (uint64_t p = 0; p < 2 * pairs; p++) boxes.push_back(std::make_unique<AsyncMailBox<uint64_t>>());
        for (uint64_t p = 0; p < pairs; p++) {
            pool.submit(ping(*boxes[2 * p], *boxes[2 * p + 1], rounds));
            pool.submit(pong(*boxes[2 * p], *boxes[2 * p + 1], rounds));
        }
        pool.join();
    };
    run_bench(f);
    measure(f, pairs * rounds * 2, "message");
}
