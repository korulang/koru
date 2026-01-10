#!/usr/bin/env python3
"""
Honest Multi-Step Benchmark - Python version
Parse and execute 3 separate strings - same as Koru
"""
import time
import sys

ITERATIONS = 10_000

def add(a, b):
    a_val = int(a)
    b_val = int(b)
    return {"sum": {"result": a_val + b_val}}

def multiply(value, by):
    val = int(value)
    by_val = int(by)
    return {"product": {"result": val * by_val}}

def subtract(value, by):
    val = int(value)
    by_val = int(by)
    return {"difference": {"result": val - by_val}}

# Three separate source strings - same as Koru
ADD_SOURCE = 'add("10", "20")'
MUL_SOURCE = 'multiply("30", "3")'
SUB_SOURCE = 'subtract("90", "5")'

def main():
    start = time.perf_counter_ns()

    final_result = 0
    for _ in range(ITERATIONS):
        # Parse and execute THREE separate strings - same as Koru
        r1 = eval(ADD_SOURCE)
        r2 = eval(MUL_SOURCE)
        r3 = eval(SUB_SOURCE)
        final_result = r3["difference"]["result"]

    elapsed_ns = time.perf_counter_ns() - start
    elapsed_ms = elapsed_ns / 1_000_000
    per_iter = elapsed_ns // ITERATIONS

    print(f"Python interpreter 3-step: {ITERATIONS} iterations", file=sys.stderr)
    print(f"Total time: {elapsed_ms:.2f} ms", file=sys.stderr)
    print(f"Per iteration: {per_iter} ns", file=sys.stderr)

    # Actual computed result
    print(f"Result: {final_result} (expected: 85)")

if __name__ == "__main__":
    main()
