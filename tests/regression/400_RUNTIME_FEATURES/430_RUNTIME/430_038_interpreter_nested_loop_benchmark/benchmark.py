#!/usr/bin/env python3
"""
HONEST APPLES-TO-APPLES BENCHMARK

Python:   for _ in range(1000): for i in range(100): add("0", str(i))
Koru:     ~for(0..1000) | each _ |> for(0..100) | each i |> add(...)

Same task. Fair comparison.
"""

import time

def add(a: str, b: str) -> dict:
    result = int(a) + int(b)
    return {"branch": "sum", "result": str(result)}

print()
print("=" * 60)
print("HONEST APPLES-TO-APPLES BENCHMARK (Python)")
print("Task: for _ in range(1000): for i in range(100): add()")
print("      = 100,000 add calls")
print("=" * 60)
print()

global_sum = 0

def add_and_accumulate(a: str, b: str) -> dict:
    global global_sum
    result = int(a) + int(b)
    global_sum += result
    return {"branch": "sum", "result": str(result)}

start = time.perf_counter_ns()

for _ in range(1000):
    for i in range(100):
        add_and_accumulate("0", str(i))

end = time.perf_counter_ns()

total_ns = end - start
total_ms = total_ns // 1_000_000

# Expected: sum(0..99) * 1000 = 4950 * 1000 = 4,950,000
expected = 4950000
print(f"Sum: {global_sum} (expected: {expected})")
print(f"Correct: {global_sum == expected}")
print(f"Time: {total_ms} ms")
print()
print("=" * 60)
