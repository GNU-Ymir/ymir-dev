from _harness import run

async def a0(x):
    return x + 1

async def a1(x):
    return (await a0(x)) + 1

async def a2(x):
    return (await a1(x)) + 1

async def a3(x):
    return (await a2(x)) + 1

async def a4(x):
    return (await a3(x)) + 1

async def a5(x):
    return (await a4(x)) + 1

async def a6(x):
    return (await a5(x)) + 1

async def a7(x):
    return (await a6(x)) + 1

async def a8(x):
    return (await a7(x)) + 1

async def a9(x):
    return (await a8(x)) + 1

async def a10(x):
    return (await a9(x)) + 1

def complete(coro):
    try:
        coro.send(None)
    except StopIteration as e:
        return e.value
    raise RuntimeError("the chain suspended")

def work():
    total = 0
    for i in range(100_000):
        total += complete(a10(i))
    return total

run(work)
