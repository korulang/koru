---
type: belief
id: frag-a-host-line-local-degrades-tor-input-binding-to-textual-substitution
provenance: first build of `unikraft/sched`; localised to a one-line function-local `const` by deleting it from a minimal repro and watching the emission change
ts: 2026-08-06
---

# `koruc` binds tor inputs to locals *unless a host line anywhere declares the same name* — then it substitutes the bare token textually, into field accesses and string literals (belief)

The comfortable belief is that a `~proc`'s inputs arrive as named locals:

```zig
pub fn handler(__koru_event_input: Input) Output {
    const box = __koru_event_input.box;
    const laps = __koru_event_input.laps;
    ...
```

That is what the emitter does **most** of the time, and it is what makes a proc
body read like ordinary Zig. It is conditional, and the condition is not one a
lift author would think to check.

## The instance

Add, anywhere in the same module's host lines, a declaration of a name a tor
takes as an input — **a function-local `const` inside an unrelated helper is
enough**:

```zig
fn total(b: *Box) u32 {
    const laps = b.laps;      // <- nothing to do with the tor
    return laps + 1;
}
```

The emitter now declines to bind `laps` and substitutes the bare token instead,
with no scope model at all:

```zig
if (__koru_event_input.laps == 0) { ... }
box.__koru_event_input.laps = __koru_event_input.laps;      // field access, rewritten
.reason = "zero __koru_event_input.laps is not a lap count" // string literal, rewritten
```

Deleting the helper and changing nothing else restores the bound local. The
trigger is the host-line declaration — not the struct field of the same name, not
a branch payload field of the same name; both were tried first and neither
reproduces it.

## Why it matters more than a compile error

The two symptoms are of different severity and only one is loud.

- `box.__koru_event_input.laps` does not exist, so the Zig build fails. Annoying,
  findable.
- `"zero __koru_event_input.laps is not a lap count"` **compiles**. A module can
  ship a corrupted diagnostic to a user, and nothing in the pipeline will say so.
  The same mechanism would corrupt any string the substitution happens to reach —
  a format template, an error message, a name written into a C struct.

## What follows

- **This is the `store.kz` disease in a different organ**: find-and-replace over
  source that has no scope model. The lesson generalises past this site — anywhere
  the toolchain rewrites emitted text by token, ask what it does inside a string
  literal, and ask it before shipping the emitter, not after.
- **A shadowing-avoidance heuristic that falls back to textual substitution is
  strictly worse than either alternative.** Binding unconditionally and letting
  Zig report the shadow would be loud; substituting only outside literals would be
  correct. Choosing the silent-corruption path to avoid a name clash trades a
  compile error for a wrong program.
- **When a lift is forced to work around this, the smallest containment is to
  move the *host-line* declaration, never the tor's surface.** The input name, the
  state names and the handle's field names are the design; an incidental local is
  not. Renaming the surface to satisfy an emitter bug is the route-around the repo
  bans, and it also hides the defect from the next reader.

## The repair, and what the belief becomes

Fixed 2026-08-08, in the two halves the analysis above already named. The
shadow collector (`collectDeclaredNames`) now tracks brace depth over host
lines — counting only braces that are code — so a function-local `const` no
longer registers as a module-level collision at all; the trigger this fragment
opens with is gone. And the substitution itself (`replaceIdentifier`) consults
a code mask (`zigCodeMask` in codegen_utils, shared by every textual tool over
host code) that marks string literals, char literals, comments and `\\`
multiline lines as text, so the rewrite that remains — for a *genuine*
module-level collision — lands only on code and can no longer corrupt a
sentence. 230_016 pins the guarantee from the outside: the corrupted output is
only observable on stdout, so the pin is a MUST_RUN on the sentence itself.

The durable lesson survives the fix: a textual tool over host code is only as
scoped as the mask it consults, and both defects here were one missing mask —
one in the collector's idea of "declared", one in the replacer's idea of
"occurrence".
