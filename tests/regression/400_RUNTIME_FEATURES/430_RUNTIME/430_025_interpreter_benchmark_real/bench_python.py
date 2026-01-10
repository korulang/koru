# REAL Python Interpreter Benchmark
# Tests: parse Python source → execute → return result
# Using eval() to parse and execute code at runtime
# Equivalent computation: 42 + 17 = 59

import time

ITERATIONS = 10_000

# The source code we'll parse and execute each iteration
# This is equivalent to Koru's ~compute(a: 42, b: 17, op: "add")
code = "42 + 17"

print("")
print("╔══════════════════════════════════════════════════════════════╗")
print("║  Python eval() Benchmark: Parse + Execute                    ║")
print("╚══════════════════════════════════════════════════════════════╝")
print("")

start = time.perf_counter_ns()

total = 0
for i in range(ITERATIONS):
    # Parse and execute Python source code each iteration
    total += eval(code)

end = time.perf_counter_ns()
elapsed_ns = end - start
elapsed_ms = elapsed_ns / 1_000_000
ops_per_sec = ITERATIONS / (elapsed_ns / 1_000_000_000)

print("Python eval():")
print(f"  Iterations: {ITERATIONS}")
print(f"  Time: {elapsed_ms:.2f}ms")
print(f"  Throughput: {int(ops_per_sec)} parse+exec/sec")
print(f"  Sum: {total} (expected: {ITERATIONS * 59})")
