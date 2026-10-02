from _harness import run
import sys
sys.setrecursionlimit(10000)

def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

def work():
    return fib(27)

run(work)
