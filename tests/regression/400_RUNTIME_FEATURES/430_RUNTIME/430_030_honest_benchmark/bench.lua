#!/usr/bin/env lua
-- Honest Multi-Step Benchmark - Lua version
-- Tests FULL interpreter: parse Lua source string -> execute
-- Apples-to-apples with Koru interpreter benchmark

local ITERATIONS = 10000

-- The functions that get called
function add(a, b)
    local a_val = tonumber(a)
    local b_val = tonumber(b)
    return { sum = { result = a_val + b_val } }
end

function multiply(value, by)
    local val = tonumber(value)
    local by_val = tonumber(by)
    return { product = { result = val * by_val } }
end

function subtract(value, by)
    local val = tonumber(value)
    local by_val = tonumber(by)
    return { difference = { result = val - by_val } }
end

-- Source strings to parse at runtime - same as Koru
local ADD_SOURCE = 'return add("10", "20")'
local MUL_SOURCE = 'return multiply("30", "3")'
local SUB_SOURCE = 'return subtract("90", "5")'

local function main()
    local start = os.clock()

    local result
    for _ = 1, ITERATIONS do
        -- Parse and execute add
        load(ADD_SOURCE)()

        -- Parse and execute multiply
        load(MUL_SOURCE)()

        -- Parse and execute subtract
        result = load(SUB_SOURCE)()
    end

    local elapsed_sec = os.clock() - start
    local elapsed_ms = elapsed_sec * 1000
    local per_iter_ns = (elapsed_sec * 1e9) / ITERATIONS

    -- Timing to stderr
    io.stderr:write(string.format("Lua interpreter 3-step: %d iterations\n", ITERATIONS))
    io.stderr:write(string.format("Total time: %.2f ms\n", elapsed_ms))
    io.stderr:write(string.format("Per iteration: %.0f ns\n", per_iter_ns))

    -- Result to stdout for verification
    print(string.format("Result: %d (expected: 85)", result.difference.result))
end

main()
