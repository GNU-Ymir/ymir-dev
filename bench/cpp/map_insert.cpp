#include "_harness.hpp"
#include <unordered_map>
#include <string>

int main() {
    volatile size_t sink;
    run_bench([&]() {
        std::unordered_map<std::string, int> m;
        for (int i = 0; i < 100000; i++) {
            m["key_" + std::to_string(i)] = i;
        }
        sink = m.size();
    });
}
