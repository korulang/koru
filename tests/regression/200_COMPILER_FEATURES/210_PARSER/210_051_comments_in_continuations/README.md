# Feature Request: Standalone Comments Inside Flow Continuations

## Status: TODO (Parser Enhancement Needed)

## Current Behavior

Standalone `//` comment lines inside flow continuations break the flow structure:

```koru
~step1()
| done |>
    // This comment breaks the flow!
    step2()
    | done |> _   // ERROR: stray continuation
```

**What happens:**
1. Parser encounters the comment line
2. Treats it as a `host_line` (Zig code passthrough)
3. Exits flow continuation parsing
4. Subsequent `| branch |>` lines become "stray continuations"

## Desired Behavior

Comments should be skipped within flow structures:

```koru
~step1()
| done |>
    // Explain what this step does
    step2()
    | done |>
        // More comments for clarity
        step3()
        | done |> _
```

## Current Workaround

Use EOL comments only:

```koru
~step1()
| done |>
    step2()                  // This works - EOL comment
    | done |> _
```

## Implementation

The parser needs to detect and skip `//` comment lines when inside a flow context,
rather than treating them as host lines that terminate the flow.

See: `src/parser.zig` - flow continuation parsing logic
