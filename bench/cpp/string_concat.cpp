#include "_harness.hpp"
#include <string>

int main() {
    volatile size_t sink;
    run_bench([&]() {
        std::string s;
        for (int i = 0; i < 20000; i++) {
            s += "tok" + std::to_string(i) + "_";
        }
        sink = s.size();
    });
}
