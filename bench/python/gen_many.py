from _harness import run

def small(seed):
    yield seed
    yield seed + 1
    yield seed + 2

def work():
    total = 0
    for i in range(1_000_000):
        g = small(i)
        total += next(g)
        total += next(g)
    return total

run(work)
