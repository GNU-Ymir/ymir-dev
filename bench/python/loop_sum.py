from _harness import run

MASK = (1 << 64) - 1

def work():
    s = 0
    for i in range(2_000_000):
        s = ((s ^ i) * 2654435761) & MASK
    return s

run(work)
