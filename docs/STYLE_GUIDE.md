# Koru Style Guide

The aesthetic of Koru: **clarity through structure, beauty through consistency.**

This guide defines canonical Koru style. Code formatted according to these rules is "beautiful Koru."

---

## 1. File Organization

A Koru file follows this order:

```
1. Module annotation (if any)
2. Imports
3. Zig constants, types, and helpers
4. Event declarations with their subflows/procs (grouped)
5. Top-level flows
```

**Example structure:**

```koru
~[comptime]

~import "$std/io"
~import "$app/domain"

const std = @import("std");

// ============================================================================
// USER MANAGEMENT
// ============================================================================

~pub event get { id: u64 }
| user User
| not_found
~get = db.lookup(id)
| found u |> user u
| missing |> not_found

// Top-level flow
~get(id: 1)
| user u |> std.io:print.ln(text: u.name)
| not_found |> _
```

### Section Headers

Use section headers for logical groupings in larger files:

```koru
// ============================================================================
// SECTION NAME
// ============================================================================
```

The header is:
- 76 characters wide (including `//`)
- ALL CAPS section name
- One blank line before, one blank line after

For smaller subsections:

```koru
// --- Subsection Name ---
```

---

## 2. Whitespace & Indentation

### Indentation

- **4 spaces** for all indentation (no tabs)
- Each nested continuation level adds 4 spaces

### Blank Lines

| Context | Blank Lines |
|---------|-------------|
| After module annotation | 1 |
| Between import groups | 1 |
| After all imports | 1 |
| Between Zig type definitions | 1 |
| Before section headers | 1 |
| After section headers | 1 |
| Between event and its subflow/proc | 0 |
| Between unrelated event groups | 2 |
| Before top-level flows | 1 |

**Example:**

```koru
~[comptime]

~import "$std/io"

const std = @import("std");

~event greet { name: []const u8 }
| greeting []const u8
~greet = greeting "Hello!"


~event farewell { name: []const u8 }
| done
~farewell = done
```

Note: Two blank lines separate unrelated event groups. Zero blank lines between an event and its subflow/proc.

### Line Length

- **Soft limit: 80 characters**
- **Hard limit: 100 characters**
- Break long lines at natural boundaries (after `|>`, before parameters)

### Trailing Whitespace

None. Ever.

---

## 3. Event Declarations

### Simple Events

Events with few short branches stay compact:

```koru
~event ping {}

~event greet { name: []const u8 }
| greeting []const u8
| error []const u8
```

### Branch Syntax

**Identity branches** (preferred) - the payload IS the type:

```koru
| message []const u8     // Branch returns a string
| count i32              // Branch returns an i32
| user User              // Branch returns a User
```

**Void branches** - just a signal, no payload:

```koru
| not_found              // No payload
| done                   // No payload
```

**Compound branches** - ONLY when multiple fields are needed:

```koru
| result { data: []u8, count: usize }    // Multiple fields needed
| error { code: i32, message: []const u8 }
```

### Branch Construction

**Identity branches** - expression after branch name:

```koru
~event status {}
| message []const u8
| code i32

~status = message "Everything OK"    // String literal
~status = code 200                   // Integer literal
~status = code error_code + 100      // Expression

// In flows
~do_something()
| success _ |> message "This succeeded"
| error e |> code e.code
```

**Identity branches with complex types** - values flow through from chaining:

```koru
~event get { id: u64 }
| user User
| not_found

~get = db.lookup(id)
| found u |> user u          // u is already a User, route it through
| missing |> not_found
```

**Void branches** - just the branch name:

```koru
~validate = check(input)
| ok |> valid
| bad |> invalid
```

**Compound branches** - use field syntax:

```koru
~event fetch {}
| result { data: []u8, count: usize }

~fetch = load(source)
| ok r |> result { data: r.bytes, count: r.len }   // Explicit fields
| ok r |> result { r.data, r.count }               // Shorthand (preferred)
```

**Rule: Use identity branches unless you need multiple fields.**

```koru
// GOOD - identity branch
~event get { id: u64 }
| user User
| not_found

// BAD - unnecessary compound wrapper
~event get { id: u64 }
| found { user: User }   // Extra indirection for no benefit
| not_found {}
```

### Branch Alignment

Branches align vertically under their event:

```koru
~pub event process { order_id: u64, user_id: u64 }
| receipt Receipt
| pending u64
| error OrderError
| ?cancelled
```

The `|` characters form a vertical line.

### Multi-line Parameters

When parameters exceed line length, break after `{`:

```koru
~event complex_operation {
    source_path: []const u8,
    destination_path: []const u8,
    options: ProcessingOptions,
}
| success { result: OperationResult }
| error { code: ErrorCode, message: []const u8 }
```

Each parameter on its own line, indented 4 spaces, with trailing comma.

### Optional Branches

Optional branches (prefixed with `?`) come last:

```koru
~event fetch { url: []const u8 }
| success { body: []const u8 }
| error { code: i32 }
| ?timeout {}
| ?cancelled {}
```

---

## 4. Subflows & Procs

**Core Principle: Prefer subflows over Zig procs.**

Subflows are pure Koru. The compiler can reason about them, optimize them, and verify their correctness. Zig procs are an escape hatch into imperative code - use them only when subflows cannot express the logic.

**The hierarchy:**
1. **Subflow (immediate)**: `~name = branch value` - simplest, most analyzable
2. **Subflow (chained)**: `~name = other() | ok |> result` - still pure, still verifiable
3. **Zig proc**: `~proc name { ... }` - imperative escape hatch, only when necessary

If you're reaching for a Zig proc, ask: *"Can this be a subflow?"*

### Subflow Style (Preferred)

No `~proc` keyword for subflows - just `~event_name = ...`:

```koru
// Direct branch mapping
~double = result { val: input * 2 }

// Short chain (fits on one line)
~validate = check(input) | ok |> valid

// Chain with binding
~process = transform(input)
| done d |> result { d.output }
```

### Zig Proc Style (Escape Hatch)

The `~proc` keyword is reserved for Zig escape hatches. Use only when subflows cannot express the logic:
- Complex conditionals that don't map to `if` events
- Loops that don't map to `for`/`each` events
- Direct Zig interop (FFI, unsafe operations)
- Performance-critical code requiring manual optimization

```koru
~proc authenticate {
    if (token.len == 0) {
        return .{ .@"error" = .{ .reason = "Empty token" } };
    }

    const user = db.lookup(token) orelse {
        return .{ .not_found = .{} };
    };

    return .{ .success = .{ .user = user } };
}
```

### Placement

The implementation immediately follows its event declaration (no blank line):

```koru
~event add { a: i32, b: i32 }
| sum i32
~add = sum a + b
```

---

## 5. Flows & Continuations

### Top-Level Flows

Top-level flows start with `~` at column 0:

```koru
~get_config()
| ok cfg |> initialize(config: cfg)
    | ready |> start_server()
| error e |> log_fatal(msg: e.reason)
```

### Continuation Indentation

Each nested continuation indents by 4 spaces:

```koru
~fetch_user(id: 42)
| found u |> fetch_permissions(user_id: u.id)
    | ok p |> validate_access(perms: p)
        | allowed |> proceed()
        | denied |> reject()
    | error |> use_defaults()
| not_found |> create_guest()
```

### The `|>` Rule

**Always break after `|>` when the continuation has further branches:**

```koru
// GOOD: breaks after |> because process has branches
~fetch(url: endpoint)
| ok data |> process(input: data)
    | success r |> save(result: r)
    | error e |> log(msg: e.reason)

// GOOD: inline is fine when continuation is terminal
~fetch(url: endpoint)
| ok data |> save(data: data)
| error |> _
```

### Void Event Chaining

Void events can chain on a single line:

```koru
~init() |> configure() |> start()
```

Or break for clarity:

```koru
~init()
|> configure()
|> start()
```

### Terminal Markers

Use `_` for terminal/discard branches:

```koru
~process()
| done |> _
| error |> _
```

### Guards (when)

Use `when` for conditional branch handling - no parentheses needed:

```koru
~get_score()
| score s when s > 100 |> excellent s
| score s when s > 50 |> good s
| score s |> needs_work s
```

The `|>` terminates the guard expression, so parentheses are unnecessary:

```koru
// GOOD - no parens
| value v when v > 0 && v < 100 |> in_range v

// BAD - unnecessary parens
| value v when (v > 0 && v < 100) |> in_range v
| value v when (v > 0) |> positive v
```

Guards are evaluated in order - put more specific guards first:

```koru
~classify(n: i32)
| num n when n > 100 |> large n     // Most specific first
| num n when n > 0 |> positive n
| num n when n < 0 |> negative n
| num _ |> zero                      // Catch-all last
```

### Labels and Jumps

Labels prefix the invocation with `#`. Jumps use `@`:

```koru
~#retry fetch(attempt: 1)
| success data |> process(data: data)
| error e |> if(e.retryable && attempt < 3)
    | then |> @retry(attempt: attempt + 1)
    | else |> fail(error: e)
```

---

## 6. Annotations

### Inline Style (Default)

For 1-3 short annotations:

```koru
~[pub] event visible {}
~[comptime|pure] proc calculate = ...
~[norun|expand] event template { ... }
```

Use `|` to separate multiple annotations. No spaces around `|`.

### Vertical Style (Complex Cases)

For many annotations or long values:

```koru
~[
-comptime
-pure
-doc("Performs complex calculation")
] proc heavy_computation { ... }
```

Each annotation on its own line, prefixed with `-`.

### Annotation Order

Standard order for common annotations:

1. Visibility: `pub`
2. Execution phase: `comptime`, `runtime`
3. Purity: `pure`
4. Behavior modifiers: `norun`, `expand`, `keyword`
5. Documentation: `doc`

---

## 7. Comments

### When to Comment

- **Do**: Explain *why*, not *what*
- **Do**: Document non-obvious design decisions
- **Don't**: State the obvious
- **Don't**: Comment every line

### Comment Style

```koru
// Single line comment for brief notes

// Multi-line comments use multiple single-line
// comment markers, not block comments

// TODO: Future work items
// FIXME: Known issues
// NOTE: Important context
```

### Inline Comments

Avoid inline comments. If needed, align them:

```koru
~event flags {
    read: bool,     // Can read resource
    write: bool,    // Can modify resource
    admin: bool,    // Full access
}
```

---

## 8. Imports

### Import Order

1. Standard library (`$std/...`)
2. Project modules (`$app/...`, `$lib/...`)

Separate groups with blank line:

```koru
~import "$std/io"
~import "$std/fs"

~import "$app/config"
~import "$app/domain/user"
```

### No Import Aliasing

Koru has **no import aliasing**. The full module path is always required in invocations:

```koru
~import "$std/io"
~import "$app/domain/user"

// Invocations use FULL paths - no shortcuts
~std.io:print.ln(text: "Hello")           // Correct
~io:print.ln(text: "Hello")               // WRONG - no aliasing

~app.domain.user:get(id: 42)              // Correct
~user:get(id: 42)                         // WRONG - no aliasing
```

The import prefix (e.g., `$std` → `std`) is defined in `koru.json`. The import statement makes the module available; the invocation always uses the full qualified path.

This explicitness is intentional: you can always tell exactly where an event comes from by reading the invocation.

---

## 9. Naming Conventions

### Events

**Don't repeat module context in event names.**

If an event lives in `user.kz`, don't name it `get_user` - name it `get`:

```koru
// In app/domain/user.kz
~event get { id: u64 }        // GOOD: app.domain.user:get(id: 42)
~event get_user { id: u64 }   // BAD:  app.domain.user:get_user(id: 42) - redundant
```

**Use underscores for compound words (single concept):**

```koru
~event read_lines { path: []const u8 }    // "read lines" = one action
~event validate_token { token: []const u8 }
~event process_order { order_id: u64 }
```

**Use dots for event families (hierarchical variants):**

```koru
// In io.kz - a family of print variants
~event print.ln { text: []const u8 }      // print with linebreak
~event print.blk { fmt: []const u8 }      // print with format block
~event print.err { text: []const u8 }     // print to stderr

// In package.kz - requires variants by package manager
~event requires.npm { packages: [][]const u8 }
~event requires.pip { packages: [][]const u8 }
~event requires.cargo { packages: [][]const u8 }
```

The anatomy of an invocation:
```
~std.io:print.ln(text: "hello")
 │    │  │     │
 │    │  │     └── variant (optional, after dot)
 │    │  └── event name
 │    └── module path (from import)
 └── import prefix (from koru.json)
```

### Branches

- **snake_case** for branch names
- Noun or adjective describing the outcome
- Examples: `success`, `not_found`, `invalid_input`

Common branch name patterns:
| Pattern | Use Case |
|---------|----------|
| `ok` / `error` | General success/failure |
| `found` / `not_found` | Lookup operations |
| `valid` / `invalid` | Validation |
| `done` | Completion without payload |
| `next` / `done` | Iteration |
| `then` / `else` | Conditionals |

### Bindings

- **Single lowercase letter** for simple bindings: `u`, `r`, `e`
- **Short descriptive name** for clarity when needed: `user`, `result`
- Match the semantic: `| found u |>` (u for user)

### Parameters

- **snake_case** for parameter names
- Descriptive but concise
- Examples: `user_id`, `file_path`, `max_retries`

---

## 10. Patterns to Prefer

### Error Handling

Always handle both success and error branches explicitly:

```koru
~fetch(url: endpoint)
| ok data |> process(data: data)
| error e |> handle_error(err: e)
```

### Early Return Pattern

For validation, fail fast:

```koru
~proc validate {
    if (input.len == 0) {
        return .{ .invalid = .{ .reason = "empty input" } };
    }
    if (input.len > MAX_LEN) {
        return .{ .invalid = .{ .reason = "too long" } };
    }
    return .{ .valid = .{ .data = input } };
}
```

### Pipeline Style

Chain transformations clearly:

```koru
~read_file(path: "data.txt")
| ok content |> parse(text: content)
    | ok data |> transform(input: data)
        | ok result |> write_file(path: "out.txt", data: result)
        | error e |> log(msg: "transform failed")
    | error e |> log(msg: "parse failed")
| error e |> log(msg: "read failed")
```

---

## Anti-Patterns

### Don't: Inconsistent Indentation

```koru
// BAD
~fetch()
| ok d |> process()
  | done |> _   // Wrong indent!

// GOOD
~fetch()
| ok d |> process()
    | done |> _
```

### Don't: Cramped Branches

```koru
// BAD
~event foo{}|ok{}|error{}

// GOOD
~event foo {}
| ok {}
| error {}
```

### Don't: Over-Comment

```koru
// BAD
// Get the user
~get_user(id: user_id)  // Call get_user with id
| found u |>  // If found
    process(user: u)  // Process the user

// GOOD
~get_user(id: user_id)
| found u |> process(user: u)
| not_found |> create_guest()
```

---

## Summary

Beautiful Koru is:

1. **Vertically aligned** - branches line up, structure is visible
2. **Horizontally compact** - no unnecessary spread
3. **Consistently indented** - 4 spaces, always
4. **Explicitly handled** - all branches addressed
5. **Meaningfully named** - intent is clear
6. **Quietly commented** - explains why, not what

The code should read like a clear specification of what happens and when.
