#include "_harness.hpp"
#include <unordered_map>
#include <string>
#include <cstdint>

static std::unordered_map<std::string, int> buildMap() {
    std::unordered_map<std::string, int> m;
    for (int i = 0; i < 100000; i++) m["key_" + std::to_string(i)] = i;
    return m;
}

static const std::unordered_map<std::string, int> m = buildMap();

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        int64_t total = 0;
        for (int i = 0; i < 100000; i++) {
            total += m.at("key_" + std::to_string(i));
        }
        sink = total;
    });
}
