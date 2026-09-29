from _harness import run
from concurrent.futures import ThreadPoolExecutor

_n = 2_000_000
_data = list(range(_n))

def partial_sum(args):
    lo, hi = args
    s = 0
    for i in range(lo, hi):
        s += _data[i]
    return s

def work():
    chunks = [(i * (_n // 4), (i + 1) * (_n // 4)) for i in range(4)]
    with ThreadPoolExecutor(max_workers=4) as ex:
        results = list(ex.map(partial_sum, chunks))
    return sum(results)

run(work)
