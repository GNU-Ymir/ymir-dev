from _harness import run

def work():
    n = 500_000
    a = [0] * n
    for i in range(n):
        a[i] = i * 2
    s = 0
    for v in a:
        s += v
    return s

run(work)
