from _harness import run

def work():
    s = ""
    for i in range(20_000):
        s += "tok" + str(i) + "_"
    return len(s)

run(work)
