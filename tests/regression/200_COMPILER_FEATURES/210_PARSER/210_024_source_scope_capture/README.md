# Test 210-024: Source Scope Capture

## Status: Working ✅

## What This Tests

A `[comptime|transform]` event that receives a `Source[HTML]` block and the
surrounding lexical scope, then rewrites the program AST at compile time to
produce a working runtime template renderer.

## The Input

```koru
~getUserData()
| data u |> renderHTML [HTML]{
        <h1>$[u.name]</h1>
        <p>Age: $[u.age]</p>
    }
    | rendered h |> std.io:println(text: h.html)
```

The `u` binding from `| data u |>` is captured in `source.scope.bindings`
and is accessible to the `renderHTML` comptime proc.

## What the Comptime Proc Does

At compile time, `~proc renderHTML`:

1. Reads `source.scope.bindings[0]` to get the captured `u` binding
2. Calls `ast_functional.resolveBindingType()` to walk the AST and determine
   the concrete type of `u` (the `data` branch of `getUserData`)
3. Parses `$[...]` interpolations from the HTML template
4. Determines format specifiers from actual field types (`[]const u8` → `{s}`,
   integers → `{d}`)
5. Generates a runtime `renderHTML` event + proc that takes a typed `u` param
   and returns `rendered { html: []const u8 }`
6. Transforms the flow to call the generated runtime event instead of the
   comptime one
7. Returns the rewritten `Program`

## Expected Output

```
<h1>Alice</h1> <p>Age: 42</p>
```
