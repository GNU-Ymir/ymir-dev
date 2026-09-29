from _harness import run

def lcg_array(n, seed=12345):
    a = [0] * n
    x = seed
    for i in range(n):
        x = (x * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        a[i] = x % 1_000_000
    return a

def work():
    a = lcg_array(50_000)
    a.sort()
    return a[0]

run(work)
