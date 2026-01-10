import time
import random

def process(value):
    return {"result": value * 2 + 1, "doubled": value * 2}

ITERATIONS = 10_000_000
random.seed(12345)

start = time.perf_counter_ns()

total = 0
for i in range(ITERATIONS):
    inp = random.randint(1, 1000)
    result = process(inp)
    total += result["result"]

end = time.perf_counter_ns()
elapsed_ms = (end - start) / 1_000_000
ops_per_sec = ITERATIONS / ((end - start) / 1_000_000_000)

print(f"Python: {elapsed_ms:.2f}ms, {ops_per_sec:.0f} ops/sec, sum={total}")
