#pragma once
#include <chrono>
#include <cstdio>
#include <functional>

template <typename F>
void run_bench(F fn, int warmup = 2, int reps = 21) {
    for (int i = 0; i < warmup; i++) fn();
    for (int i = 0; i < reps; i++) {
        auto t0 = std::chrono::high_resolution_clock::now();
        fn();
        auto t1 = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        printf("%.6f\n", ms);
    }
}
