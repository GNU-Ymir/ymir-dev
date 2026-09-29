from _harness import run

class MyError(Exception):
    pass

def work():
    total = 0
    for i in range(20_000):
        try:
            raise MyError("boom")
        except MyError:
            total += 1
    return total

run(work)
