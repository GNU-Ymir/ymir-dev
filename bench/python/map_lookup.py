from _harness import run

_m = {}
for i in range(100_000):
    _m["key_" + str(i)] = i

def work():
    total = 0
    for i in range(100_000):
        total += _m["key_" + str(i)]
    return total

run(work)
