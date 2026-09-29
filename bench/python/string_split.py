from _harness import run

_src = ",".join(str(i) for i in range(30_000))

def work():
    total = 0
    for tok in _src.split(","):
        total += int(tok)
    return total

run(work)
