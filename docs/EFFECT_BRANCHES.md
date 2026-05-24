# Effect branches (`!`) — workdoc

**Status**: Design phase.

## Summary

A new branch flavor for events, marked `!` instead of `|`. Yielding branches are Koru's algebraic effects: producer `perform`s an operation, consumer `handle`s it, handler body is the interpretation. Lowers to a `comptime`-typed handler struct, monomorphized per call site. No coroutines, no fn-pointer indirection, pure static dispatch.

## Motivation

Pump-shaped procs (event loops, iterators, tokenizers, parsers, vaxis-style TUIs) today force one of two bad shapes:
- Consumer calls the proc N times, threading state via phantom types each call.
- Proc builds an internal state machine, consumer re-enters via outer loop.

Both encode "this is a stream" by hand. Neither composes with phantom-state obligations cleanly. The body does heavy lifting that should belong to the language.

## Syntax

### Event declaration

```
~pub event for { start: usize, end: usize }
! each usize
| done usize
```

- `!` branches: effect operations. May fire zero-or-more times during a single proc invocation.
- `|` branches: terminal (exactly one fires, the proc returns).
- `!` branches always come first in source order at the declaration.
- An event with only `!` branches and no `|` is fine — it's a void event with effect operations. The producer runs to its natural end and returns.

### Optional effect branches (`!?`)

Symmetric with the existing `|?` mechanism for terminal branches. An event can declare a effect branch as optional with a `?`-prefixed name; consumers may omit handlers for those branches without an exhaustiveness error, and an unhandled call from the producer becomes a no-op.

```
~pub event tokenize { source: []const u8 }
! token Token
! ?warning []const u8
! ?debug []const u8
| done usize
```

- `! ?warning []const u8`: optional effect branch. Consumer is free to handle it or ignore it.
- Catch-all dispatch via `!?`, mirroring `|?`:

```
~tokenize(source: src)
! token t |> emit(t)
!? |> _                  // ignore all unhandled optional effect branches
| done _ |> _
```

- `!? Metatype binding |> body` is also legal, again mirroring `|?` (e.g., filter all unhandled yields through a metatype binding).
- Producer-side semantics: calling an unhandled optional effect branch is a no-op (silently dropped). The handler simply isn't installed in the comptime struct, so the call lowers to nothing.

Optional effect branches are expected to be the bread-and-butter shape for pump-style events that emit multiple kinds of signals (tokens + warnings + debug traces, frames + metrics + log lines, etc.). Most consumers only care about a subset; making everything required would force `! everything _ |> _` boilerplate in every consumer.

Convention (matching `|`): required `!` first, then optional `!?` next, then required `|`, then optional `|?`. Enforcement is convention-only at the parser layer; the `!`-before-`|` rule is the only hard ordering constraint.

### Resume values

`!` branches can yield in both directions. The `->` notation declares a resume type:

```
~pub event prompt_user { question: []const u8 }
! ask []const u8 -> []const u8
| done
```

- `! ask []const u8 -> []const u8`: yield a `[]const u8` prompt, resume with a `[]const u8` reply.
- `! each usize`: equivalent to `! each usize -> void`. Pure side-effecting yield, no reply.

Default omitted resume is `-> void`.

Optional effect branches can also carry resume types: `! ?prompt []const u8 -> []const u8` is a effect branch the consumer may skip; when handled, it resumes with the supplied value; when unhandled, the call is a no-op AND the producer-side resume is the default-of-resume-type (e.g., `""` for `[]const u8`, `0` for numeric, `void` for void). Whether default-of-type is acceptable here or whether unhandled optional with a non-void resume should be a compile error is an open question.

### Glyph choice — why `!`

`!` is already Koru's effect-tag in `[state!]` (creates obligation) and `[!state]` (discharges obligation). Promoting it to a branch-dispatch position for "this branch is an effect operation" makes `!` a unifying mark across the type system: same glyph for *type system has something effect-shaped to track here*, whether it's lifecycle-effect (obligation) or control-flow-effect (yield). The position-based disambiguation (`!` inside `[...]` vs `!` at branch-line-start) is straightforward for both parser and reader.

### Ordering rule

`!` before `|`, at both event decl and dispatch sites. Hard-enforced by parser. Reasoning:
- Source order = temporal order. Effects during run, then how it ends.
- Reader knows where to look: top = operations, bottom = termination.
- Prevents accidentally pattern-matching a terminal and missing an effect-handler in between.

### Dispatch site (consumer)

```
~count_to_three = for(0..3)
! each _ |> std.io:println(text: "counting")
| done |> result 3
```

Exhaustiveness on both: every required `!` branch must be handled, every required `|` branch must be handled. Optional `!?` and `|?` branches do not need explicit handlers — unhandled optional yields are no-ops (see optional effect branches section above), unhandled optional terminals follow the existing `|?` rules. A `!?` or `|?` catch-all in the dispatch list absorbs any optional branches not explicitly named. Branches-are-equal exhaustiveness, layered. The handler body's tail value is the resume value (when the branch has a `->` resume type).

### Proc impl (host language)

```
~impl for(start: usize, end: usize) {
    var i = start;
    while (i < end) : (i += 1) {
        each(i);
    }
    return .{ .done = i };
}
```

Each `!` branch is in scope inside the body as a callable named after the branch. Calling `each(...)` transfers control to the consumer's `! each` handler synchronously, runs it, returns control. The body terminates by returning a `|` branch shape, same as today.

## Semantics

### Lowering — comptime struct type

Each call site synthesizes a struct type carrying the consumer's handler bodies as static `fn`s on it; the proc takes `comptime H: type` and accesses handlers via `H.branch_name`. Pattern verified against existing emission style at `tests/regression/400_RUNTIME_FEATURES/400_061_phantom_autodispose/output_emitted.zig`.

```zig
// At the call site (synthesized by the emitter):
pub fn flow1() void {
    const Handlers = struct {
        fn each(i: usize) void {
            std.debug.print("counting\n", .{});
        }
    };
    const result = main_module.for_event.handler(.{ .start = 0, .end = 3 }, Handlers);
    _ = result.done;
}

// The impl:
pub fn handler(input: Input, comptime H: type) Output {
    const each = H.each;  // comptime alias, zero cost
    var i = input.start;
    while (i < input.end) : (i += 1) each(i);
    return .{ .done = i };
}
```

What this gives:
- `comptime H: type` means Zig monomorphizes per call site before LLVM. Direct call in IR, guaranteed — no LLVM-devirtualization gamble.
- The body can `const each = H.each;` to recover bare-name ergonomics. Comptime alias = zero runtime cost.
- Matches existing emit style. Today's flows already inline result-bindings; tomorrow's also inline handler bodies into a synthesized struct type.

No fn-pointers anywhere. No coroutines, no async, no resumption magic.

### Obligation rule — narrow

`!` branches CAN CREATE obligations per-call, in both yield-payload and resume-value positions. Each call produces an independent obligation that is discharged within its own iteration (handler body for payload obligations, producer body for resume obligations).

`!` branches CANNOT DISCHARGE obligations. The 0-to-N call-count semantics make "this branch discharges an obligation" incoherent — you can't have 47 discharges of a single obligation, or 0 discharges of one that exists.

This is a little obtuse for the proc-implementor (per-call obligation lifecycle is a new kind of reasoning) but the math is local, not cross-call.

### Phantom types

Plain phantom states (`[state]`, no `!`) flow through `!` branches with no restriction.

### Purity

`!` branches are effectful in the algebraic sense — the producer surrenders control to opaque user code each call. Transitive-purity tracking should treat a proc with `!` branches as effectful unless every handler at the call site is itself pure. A `[pure]` annotation on such a proc would demand purity of every passed-in handler.

### Producer shape

The producer body does NOT need to be a loop. A single straight-line producer that calls `each(x)` once and then returns a terminal is fine. The number of yields (0, 1, many, infinite) is up to the body.

## Open questions

1. **Consumer-initiated termination for iterating producers.** Partially solved by resume values: handler can return a sentinel that the producer checks. But for cleaner ergonomics in long-running pumps (vaxis-style), a `@scope`-shaped break-from-handler mechanism may be warranted. Doesn't apply to single-shot producers.

2. **Re-entrancy.** Can a consumer's handler call back into another proc that has `!` branches? Probably yes by default (nested function calls), but phantom-state and obligation interaction needs to be walked through.

3. **`!` calls from inside `|` terminal emit.** Can the producer body call `each(...)` from inside the terminal-emit code (e.g., emit a final batch right before returning `done`)? Probably yes — `each` is just a function — but worth confirming.

4. **Subflows.** Can a subflow `~event = subflow_body` define `!` branches? Pure-passthrough probably trivial; subflow-interpreted ones probably murky. Relates to the variants-only-on-procs rule.

5. **Multi-event namespacing.** When a single proc impl handles multiple events that share branch names, names collide. Lean: bare-when-unique, namespace-when-collision (`event_name.branch_name`). The compiler knows at emission time. Alternative: always namespace, simpler rule, slightly more ceremonious in the common case.

6. **`return` vs last-expression for resume value.** Last-expression matches the rest of the flow language. Explicit `return` distinguishes "handler resumes with value X" from "handler decides to bail entirely." Worth picking deliberately.

7. **Phantom types in resume direction.** Symmetric with payload (handler resumes with `*T[state!]` create-obligation, producer discharges in body before next iteration). Powerful but doubles the obligation-flow analysis surface. Land or defer?

## Implementation phases

Order matters; each phase should land separately.

1. **Parser**: accept `!` at decl + dispatch positions; enforce ordering rule; accept `->` resume-type syntax.
2. **Shape checker**: validate `!`/`|` matching between event decl and consumer dispatch; validate resume-type matching.
3. **Emission**: synthesize per-call-site handler struct type; pass as `comptime H: type` to the impl; emit `H.branch_name` access in the body.
4. **Phantom checker**: extend obligation tracking through `!` branch yield and resume payloads, with the narrow rule (create OK, discharge forbidden).
5. **Stdlib**: rewrite `for`, range iterators, and any existing pump-shaped events using the new shape.
6. **Test sweep**: rewrite affected regression tests.

## Test impact

Rough estimate: large. Pump-shaped events appear across iterators, loops, and any code that emits-then-continues. A pre-pass should grep for current usages to scope the sweep before phase 5.

## Migration

None. New form replaces old in the same diff. No synonyms, no deprecation window, no dual-acceptance period.
