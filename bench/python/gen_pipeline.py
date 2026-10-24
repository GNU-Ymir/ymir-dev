from _harness import run

def rng(n):
    i = 0
    while i < n:
        yield i
        i += 1

def work():
    return sum(filter(lambda x: x % 2 == 0, map(lambda x: x * 3, rng(10_000_000))))

run(work)
