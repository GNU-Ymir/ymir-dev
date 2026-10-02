from _harness import run

def work():
    m = {}
    for i in range(100_000):
        m["key_" + str(i)] = i
    return len(m)

run(work)
