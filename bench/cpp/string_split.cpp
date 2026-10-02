#include "_harness.hpp"
#include <string>
#include <sstream>
#include <cstdint>

static std::string buildSrc() {
    std::string s;
    for (int i = 0; i < 30000; i++) {
        if (i) s += ",";
        s += std::to_string(i);
    }
    return s;
}

static const std::string src = buildSrc();

int main() {
    volatile int64_t sink;
    run_bench([&]() {
        int64_t total = 0;
        size_t start = 0;
        while (start <= src.size()) {
            size_t comma = src.find(',', start);
            std::string tok = (comma == std::string::npos)
                ? src.substr(start)
                : src.substr(start, comma - start);
            total += std::stoll(tok);
            if (comma == std::string::npos) break;
            start = comma + 1;
        }
        sink = total;
    });
}
