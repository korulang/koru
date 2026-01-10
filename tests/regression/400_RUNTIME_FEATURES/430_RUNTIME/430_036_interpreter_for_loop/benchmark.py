#!/usr/bin/env python3
"""
HONEST PYTHON BENCHMARK - Compare with Koru interpreter

Task: Same as Koru benchmark
- Simple dispatch: add(21, 21)
- Loop: for i in range(100): add(0, i)
"""

import time

ITERATIONS = 1000

# Simulate event dispatch
def add(a: str, b: str) -> dict:
    result = int(a) + int(b)
    return {"branch": "sum", "result": str(result)}

def init_sum() -> dict:
    return {"branch": "value", "n": "0"}

print()
print("=" * 60)
print("HONEST PYTHON BENCHMARK")
print("=" * 60)
print()

# BENCHMARK 1: Simple dispatch
print(f"[1] SIMPLE DISPATCH: add('21', '21')")
print(f"    Iterations: {ITERATIONS}")

# Warm up
for _ in range(10):
    add("21", "21")

start = time.perf_counter_ns()
for _ in range(ITERATIONS):
    add("21", "21")
end = time.perf_counter_ns()

total_ns = end - start
per_iter_ns = total_ns // ITERATIONS

print(f"    Total: {total_ns // 1_000_000} ms")
print(f"    Per dispatch: {per_iter_ns} ns")
print()

# BENCHMARK 2: Loop with dispatches (equivalent to for(0..100))
print(f"[2] LOOP: for i in range(100): add('0', str(i))")
print(f"    Iterations: {ITERATIONS}")

# Warm up
for _ in range(3):
    for i in range(100):
        add("0", str(i))

start = time.perf_counter_ns()
for _ in range(ITERATIONS):
    for i in range(100):
        add("0", str(i))
end = time.perf_counter_ns()

total_ns = end - start
per_iter_ns = total_ns // ITERATIONS
per_iter_us = per_iter_ns // 1000

print(f"    Total: {total_ns // 1_000_000} ms")
print(f"    Per execution: {per_iter_us} us ({per_iter_ns} ns)")
print(f"    (Each execution = 100 loop iterations + 100 add calls)")
print()
print("=" * 60)
