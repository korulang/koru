import time

class PRNG:
    def __init__(self, seed):
        self.state = seed
    def next(self, max_val):
        self.state = (self.state * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        return (self.state >> 33) % max_val

def add_handler(a, b): return a + b
def mul_handler(a, b): return a * b
def sub_handler(a, b): return a - b
def div_handler(a, b): return a // b if b != 0 else 0

handlers = {"add": add_handler, "mul": mul_handler, "sub": sub_handler, "div": div_handler}
events = ["add", "mul", "sub", "div"]

def dispatch(event_name, a, b):
    return handlers[event_name](a, b)

ITERATIONS = 10_000_000
prng = PRNG(12345)

start = time.perf_counter_ns()

total = 0
for i in range(ITERATIONS):
    event_idx = prng.next(4)
    a = prng.next(100) + 1
    b = prng.next(100) + 1
    total += dispatch(events[event_idx], a, b)

end = time.perf_counter_ns()
elapsed_ms = (end - start) / 1_000_000
ops_per_sec = ITERATIONS / ((end - start) / 1_000_000_000)

print(f"HONEST Python: {elapsed_ms:.2f}ms, {int(ops_per_sec)} ops/sec, sum={total}")
