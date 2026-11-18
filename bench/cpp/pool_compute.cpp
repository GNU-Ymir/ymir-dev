#include "_harness.hpp"
#include "_pool.hpp"

// The terms [lo, hi) of the midpoint sum of the integral of 4 / (1 + x²) over [0, 1], in n steps.
static double compute_pi(uint64_t lo, uint64_t hi, uint64_t n) {
    double res = 0.0, step = 1.0 / double(n);
    for (uint64_t i = lo; i < hi; i++) {
        double x = (double(i) + 0.5) * step;
        res += 4.0 / (1.0 + x * x);
    }
    return res * step;
}

static Async<void> part(std::vector<double>& parts, uint64_t t, uint64_t slice, uint64_t tasks) {
    parts[t] = compute_pi(t * slice, (t + 1) * slice, tasks * slice);
    co_return;
}

int main(int argc, char** argv) {
    const uint64_t tasks = 10000, slice = 10000;
    unsigned workers = argc > 1 ? unsigned(std::atoi(argv[1])) : 4;
    TaskPool pool(workers ? workers : 4);
    std::vector<double> parts(tasks);
    auto f = [&]() {
        for (uint64_t t = 0; t < tasks; t++)
            pool.submit(part(parts, t, slice, tasks));
        pool.join();
    };
    run_bench(f);
    measure(f, tasks);
    double pi = 0.0;
    for (double p : parts) pi += p;
    if (pi < 3.14 || pi > 3.15) fprintf(stderr, "wrong pi: %f\n", pi);
}
