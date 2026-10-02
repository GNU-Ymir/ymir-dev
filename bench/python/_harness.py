import time

def run(fn, warmup=2, reps=21):
    for _ in range(warmup):
        fn()
    for _ in range(reps):
        t0 = time.perf_counter()
        fn()
        t1 = time.perf_counter()
        print(f"{(t1 - t0) * 1000.0:.6f}")
