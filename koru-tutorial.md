# Koru in a Page

> Generated 2026-06-01T00:54:39.224Z by `scripts/generate-tutorial.js` from `koru-by-example.json`.

> **Note:** This tutorial is prose synthesis on top of the test suite. It may contain errors or drift. The compiler's actual behavior — verified by tests in `tests/regression/` and source in `src/` — is the source of truth. When you find this document saying one thing and the compiler doing another, the conflict itself is the finding: flag it, don't paper over it.
>
> **Koru is greenfield.** There are no legacy users, no deprecated forms to support, no migration windows that constitute a contract. When the language changes, the change lands and tests/docs get rewritten in the same motion. If the parser temporarily accepts an older form while migration is in progress, that's internal scaffolding — not a feature. Write code in the current canonical form. Don't hedge for legacy.

Koru is an event-continuation language. It lives on top of a host language — the implementation here targets Zig, so this file (`.kz`, for *Koru Zig*) is the Koru-Zig variant. A `.kz` file is a valid Zig file: lines starting with `~` switch the parser into Koru mode for that construct, everything else stays plain Zig. Pure Zig works as-is — you can write a `.kz` file that's nothing but `pub fn main()` and it compiles. Add Koru where it earns its keep: events with named outcome branches, flows that dispatch on those branches, subflows that compose them. The language is small. Read this top to bottom and you can write it.

## The rules

### The tilde is parser mode, not a function call

`~` at the start of a top-level construct switches the parser from Zig to Koru. `~event`, `~proc`, `~import`, `~event_name(...)` — all parser-mode switches. Anything *outside* a Koru block is the host language — even a `// comment` between two `~event` declarations is parsed by Zig, not Koru. Inside a flow's continuation you're already in Koru, so `~` doesn't belong there — writing it silently creates a second unrelated flow.

```koru
~greet(name: "World")        // ~ here: switching to Koru
| greeting g |> process(g)   // NO ~ here: already in Koru
```

### Events declare named outcomes; branches are equal

An event has input fields and zero or more named branches. Each branch is a possible outcome with its own payload shape, which takes one of three forms:

- **Empty**: `| name` — the branch name itself is the dispatch payload. Allowed only when the event has more than one branch; a single empty-payload branch is rejected — it carries no information beyond *the event happened*, so declare a void event (no branches at all) instead.
- **Identity**: `| name T` — binds a single typed value.
- **Struct**: `| name { a: A, b: B }` — multiple named fields (must be more than one; single-field structs are rejected — use identity instead).

The branch *names* are arbitrary identifiers — there is no privileged 'success' or 'error', no implicit happy path. `| ok`, `| err`, `| north`, `| return`, `| break` are all the same kind of thing. The meaning of a branch name comes from the subflow that resolves it, not from the compiler.

A void event (no branches at all) is allowed and means 'this event has nothing to say beyond having happened.'

### Subflows implement events in Koru; procs are the host escape hatch

An event is implemented by a **subflow** — pure Koru, no host code — in one of two shapes:

- **Immediate**: `~name = branch_name payload_expr` directly emits a branch with a value. `~greet = greeting "Hello, " ++ name ++ "!"` emits `greeting` with the formatted string.
- **Composition**: `~name = sub_event() | branch |> ... | branch |> ...` invokes another event and maps its branches into this event's outcomes. **Branch selection lives here, in Koru:**

```koru
~run = step()
| return |> stopped
| break |> stopped
| continue |> iterated
```

Choosing which outcome to emit — including with `when`-guards on the branches (see the next rule) — is a Koru act, not a host one. Subflows are the fractal heart of Koru: a program is itself a subflow, branch constructors are tiny anonymous subflows, everything is input → transformation → output.

When you genuinely need the host — an actual **side effect**, or **collecting data across a call** until Koru grows a first-class feature for it — a proc provides a host-language body: `~proc name|zig { ... }` is the Zig-variant, opaque to Koru and passed straight through. (The `|zig` is the variant tag; the same mechanism is what would target other hosts.) The proc is the escape hatch, not the default. **If a proc body is only selecting a branch with an `if`, it wants to be a subflow.**

### Flows dispatch with `|`, chain with `|>`

A flow invocation lists each branch and what to do with it. `| branch binding |> next_step()` captures the branch payload and pipes it to the next event. `|> _` terminates a branch.

```koru
~check(value: 42)
| positive p |> handle_positive(n: p)
| zero |> handle_zero()
| negative n |> handle_negative(n)
```

Punning is mandatory: when a call argument's value is exactly the field name, write `handle_negative(n)` — the compiler rejects the redundant `handle_negative(n: n)`. A label is for when the value differs from the field, like `handle_positive(n: p)` above.

Every branch must be handled — the compiler enforces exhaustiveness. Inline chains like `A() |> B() |> C()` compose void events on one line. `|>` never starts a line; if a chain gets long, refactor.

A `when` clause narrows a handler to a subset of fires that match a predicate — `| key k when k.code == 'p' |> handle_pause()`. Multiple `when`-guarded handlers for the same branch are allowed; they're tried top-down. A guarded handler does NOT satisfy coverage on its own — every required branch needs at least one unguarded sibling. Write the predicate bare: `when k.code == 'p'`, not `when (k.code == 'p')`. The same `when` works on `!` effect-branch handlers.

### `~if` — the fast conditional, a convention over `when`

`~if(cond) | then |> ... | else |> ...` selects one of two terminal continuations on a condition — branch selection in pure Koru, no proc needed:

```koru
~if(value > 10)
| then |> std.io:println(text: "big")
| else |> std.io:println(text: "small")
```

`~if` is a *convenience, not a primitive* — it is a specialization of `when`-branches (the same selection is expressible with a guarded branch), kept because it reads clearly and lowers to fast code. It is a template proc: it runs no effects, it just *returns* the `then` or `else` continuation and the consumer dispatches on it — the same machine as `for` with the during-half empty. `~if` is available as a keyword once you import any `$std` module.

This is the form Rule 3's sibling points at: when a proc body would only be selecting a branch with a host `if`, reach for `~if` and keep it in Koru.

### Phantom states are compile-time type labels

Attach a state label to a type: `*File<opened>`. The label is opaque to the language; meaning comes from a *semantic checker pass*. The default checker treats labels as resource-lifecycle states and tracks them through event signatures — but the mechanism is pluggable, and custom checkers can interpret labels however they want.

Simplest case: a phantom label as a *unit of measure*, attached to a primitive type. No obligation involved; the compiler just refuses to let you cross units.

```koru
~event read_temp { sensor_id: u8 }
| reading f32<celsius>

~event to_fahrenheit { c: f32<celsius> }
| result f32<fahrenheit>
```

`to_fahrenheit` won't accept a bare `f32` or an `f32<fahrenheit>` — only `f32<celsius>`. The conversion event declares the unit transition at its boundary.

For resource lifecycle, layer *obligations* on top: `<state!>` on a return *produces* a cleanup obligation; `<!state>` on a parameter *discharges* one. The compiler refuses to let an obligated resource fall off the end of a flow without being passed to a `<!state>` parameter somewhere.

```koru
~event open { path: []const u8 }
| opened *File<opened!>              // <opened!> produces a cleanup obligation

~event close { file: *File<!opened> }   // <!opened> discharges it
```

`open` hands back a file with an obligation the compiler tracks until something accepts it via `<!opened>` — `close` is that something. Try to drop the file (`| opened f |> _`) and the compiler stops you.

The compiler does NOT verify that the disposal proc actually cleans up — that's the library author's promise. Usage correctness is checked; library correctness is verified by tests.

### Effect branches yield mid-proc to the caller

`! name payload` on an event declares an *effect branch* (vs. `| name` which is a terminal outcome). The proc body invokes it like a function call, which transfers control to the caller's `! name binding |> body` handler, runs the handler, then returns to the proc. Different from continuations: a continuation runs *after* the proc returns; an effect-branch handler runs *during* it.

A producer can declare any number of effect branches; the handler is selected by name at the call site. A `ticker` that alternates two effects:

```koru
~pub event ticker { n: usize }
! tick usize
! tock usize

~proc ticker|zig {
    for (0..n) |i| {
        if (i % 2 == 0) tick(i) else tock(i);
    }
}

~ticker(n: 5)
! tick i |> std.io:print.ln("tick {{ i:d }}")
! tock i |> std.io:print.ln("tock {{ i:d }}")
```

Output:

```
tick 0
tock 1
tick 2
tock 3
tick 4
```

---

## Examples

### 010_001_hello_world

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test: Pure Zig code in a .kz file
// ============================================================================
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello World\n", .{});
}
```

**Output:**

```
Hello World
```

### 010_000_hello_world_koru

```koru
const name = "World";
const debug = true;
const count: i32 = 42;

// Hello World in pure Koru.
// This is the frontpage example from korulang.org.

~import "$std/io"

~std.io:print.blk {
    {% if debug %}[DEBUG] {% endif %}Hello, {{ name:s }}!
    The answer is {{ count:d }}.
}
```

**Output:**

```
[DEBUG] Hello, World!
The answer is 42.
```

### 020_014_pure_subflow_impl

```koru
// Test: Pure subflow implementation (no proc needed)
// From the README example - this is idiomatic Koru
// This is the default authoring model for ordinary event behavior.
~import "$std/io"

~event greet { name: []const u8 }
| greeting []const u8

~greet = greeting "Hello, " ++ name ++ "!"

~greet ("World")
| greeting msg |> std.io:print.ln(msg)
```

**Output:**

```
Hello, World!
```

### 201_multiple_branches

```koru
// ============================================================================
// VERIFIED REGRESSION TEST - DO NOT MODIFY WITHOUT DISCUSSION
// ============================================================================
// Test 007: Multiple branches in events
// Tests that events can have multiple branches and procs can return different ones
const std = @import("std");

~event check { value: i32 }
| positive i32
| zero
| negative i32

~proc check|zig {
    if (value > 0) return .{ .positive = value };
    if (value < 0) return .{ .negative = value };
    return .{ .zero = .{} };
}

~event handle_positive { n: i32 }

~proc handle_positive|zig {
    std.debug.print("Positive branch works: {}\n", .{n});
}

~event handle_zero {}

~proc handle_zero|zig {
    std.debug.print("Zero branch works\n", .{});
}

~event handle_negative { n: i32 }

~proc handle_negative|zig {
    std.debug.print("Negative branch works: {}\n", .{n});
}

// Test 1: Positive value (42)
~check(value: 42)
| positive p |> handle_positive(n: p)
| zero |> handle_zero()
| negative n |> handle_negative(n)

// Test 2: Zero value (0)
~check(value: 0)
| positive p |> handle_positive(n: p)
| zero |> handle_zero()
| negative n |> handle_negative(n)

// Test 3: Negative value (-7)
~check(value: -7)
| positive p |> handle_positive(n: p)
| zero |> handle_zero()
| negative n |> handle_negative(n)
```

**Output:**

```
Positive branch works: 42
Zero branch works
Negative branch works: -7
```

### 240_subflow_defines_semantics

```koru
// Test 240: subflows define branch semantics
//
// Branch names in Koru are inert identifiers. Their meaning — what
// "return", "break", "continue", "ok", "north", or any other name
// signifies — is defined by the SUBFLOWS that resolve them, not by
// the compiler. This is the structural advantage over languages that
// bake fixed semantics for certain names into their grammar.
//
// This test deliberately uses names that ARE keywords in other
// languages (return, break, continue), to verify that the parser
// carries no value judgment about them. If a "common mistakes from
// other languages" trap is re-introduced at parser.zig parseStep,
// this test fails. That is the point.

~import "$std/io"

// Lower-level event: arbitrary outcome names
~pub event step {}
| return
| break
| continue

~step = continue

// Outer event: its own outcome vocabulary
~pub event run {}
| stopped
| iterated

// Subflow: `run` is satisfied by `step`, with `step`'s outcomes
// mapped to `run`'s. The meaning of `return`, `break`, `continue`
// lives HERE — in user code, not in the compiler.
~run = step()
| return |> stopped
| break |> stopped
| continue |> iterated

~std.io:print.ln("Testing subflow-defined semantics:")
~run()
| stopped |> std.io:print.ln("  stopped")
| iterated |> std.io:print.ln("  iterated")
```

**Output:**

```
Testing subflow-defined semantics:
  iterated
```

### 330_005_cleanup_obligation_satisfied

```koru
~import "$app/fs"
~app.fs:open(path: "test.txt")
| opened f |> app.fs:close(file: f)
```

**Output:**

```
Opening file: test.txt
Closing file
```

### 400_070_effect_branch_minimal

```koru
// Test: minimum effect-branch program — proc yields, consumer handles.
//
// `! pong []const u8` is an effect branch; the proc body calls `pong(msg)`
// which transfers control to the consumer's `! pong reply |> ...` handler,
// runs it, then returns. No terminal `|` branches — this is a void event
// with one effect operation.

~import "$std/io"

const std = @import("std");

~pub event ping { msg: []const u8 }
! pong []const u8

~proc ping|zig {
    pong(msg);
}

~ping(msg: "hello effect branches")
! pong reply |> std.io:print.blk {
    {{ reply:s }}
}
```

**Output:**

```
hello effect branches
```

