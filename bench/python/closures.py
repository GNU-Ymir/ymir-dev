from _harness import run

_data = list(range(500_000))

def work():
    f = lambda x: x * x + 1
    return sum(map(f, _data))

run(work)
