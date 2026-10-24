#pragma once
#include <coroutine>
#include <exception>
#include <utility>

// A generator: lazy, resumed by next, its frame destroyed with it.
template <typename T>
struct generator {
    struct promise_type {
        T value;
        generator get_return_object() { return generator{handle::from_promise(*this)}; }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        std::suspend_always yield_value(T v) noexcept { value = v; return {}; }
        void return_void() noexcept {}
        void unhandled_exception() { std::terminate(); }
    };
    using handle = std::coroutine_handle<promise_type>;

    handle h;
    explicit generator(handle h) : h(h) {}
    generator(generator&& o) noexcept : h(std::exchange(o.h, {})) {}
    ~generator() { if (h) h.destroy(); }

    bool next(T& out) {
        h.resume();
        if (h.done()) return false;
        out = h.promise().value;
        return true;
    }
};

// A lazy task: started by run or by the task awaiting it, which it resumes once it completes.
template <typename T>
struct task {
    struct promise_type {
        T value;
        std::coroutine_handle<> cont = std::noop_coroutine();
        task get_return_object() { return task{handle::from_promise(*this)}; }
        std::suspend_always initial_suspend() noexcept { return {}; }
        struct final_awaiter {
            bool await_ready() noexcept { return false; }
            std::coroutine_handle<> await_suspend(std::coroutine_handle<promise_type> h) noexcept { return h.promise().cont; }
            void await_resume() noexcept {}
        };
        final_awaiter final_suspend() noexcept { return {}; }
        void return_value(T v) noexcept { value = v; }
        void unhandled_exception() { std::terminate(); }
    };
    using handle = std::coroutine_handle<promise_type>;

    handle h;
    explicit task(handle h) : h(h) {}
    task(task&& o) noexcept : h(std::exchange(o.h, {})) {}
    ~task() { if (h) h.destroy(); }

    bool await_ready() noexcept { return false; }
    std::coroutine_handle<> await_suspend(std::coroutine_handle<> c) noexcept {
        h.promise().cont = c;
        return h;
    }
    T await_resume() noexcept { return h.promise().value; }

    T run() {
        h.resume();
        return h.promise().value;
    }
};
