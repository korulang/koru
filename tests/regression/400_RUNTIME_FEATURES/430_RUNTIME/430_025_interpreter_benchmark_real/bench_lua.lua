-- REAL LuaJIT Interpreter Benchmark
-- Tests: parse Lua source → execute → return result
-- Using loadstring() to parse and execute code at runtime
-- Equivalent computation: 42 + 17 = 59

local ITERATIONS = 10000

-- The source code we'll parse and execute each iteration
-- This is equivalent to Koru's ~compute(a: 42, b: 17, op: "add")
local code = "return 42 + 17"

print("")
print("╔══════════════════════════════════════════════════════════════╗")
print("║  LuaJIT loadstring() Benchmark: Parse + Execute              ║")
print("╚══════════════════════════════════════════════════════════════╝")
print("")

local start = os.clock()

local sum = 0
for i = 1, ITERATIONS do
    -- Parse and execute Lua source code each iteration
    local fn = loadstring(code)
    sum = sum + fn()
end

local elapsed = os.clock() - start
local elapsed_ms = elapsed * 1000
local ops_per_sec = ITERATIONS / elapsed

print("LuaJIT loadstring():")
print(string.format("  Iterations: %d", ITERATIONS))
print(string.format("  Time: %.2fms", elapsed_ms))
print(string.format("  Throughput: %d parse+exec/sec", math.floor(ops_per_sec)))
print(string.format("  Sum: %d (expected: %d)", sum, ITERATIONS * 59))
