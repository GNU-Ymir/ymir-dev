from _harness import run

class Base:
    def value(self):
        return 0

class A(Base):
    def value(self):
        return 1

class B(Base):
    def value(self):
        return 2

_objs = [A() if i % 2 == 0 else B() for i in range(1000)]

def work():
    total = 0
    for _ in range(1000):
        for o in _objs:
            total += o.value()
    return total

run(work)
