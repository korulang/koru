---
type: belief
id: frag-the-host-compilers-diagnostics-hid-the-absence-of-ours
provenance: probing what `f(n)` should do when `n` is also a declared field; the answer required knowing what an omitted required argument does today, and it does nothing
ts: 2026-08-02
---

# Zig's diagnostics hid the fact that Koru had none (belief)

Koru has no call-site arity check. Ten months, 1454 tests, and a required tor
input can simply be omitted. Measured, all four cells:

| call site | impl | today |
| --- | --- | --- |
| required param omitted, impl never reads it | subflow | **compiles, runs, silent** |
| required param omitted, impl reads it | subflow | raw Zig `use of undeclared identifier 'b'` |
| required param omitted | `\|zig` proc | raw Zig `missing struct field: b` |
| required `Expression` param omitted | either | **compiles, silent** |

`KORU080 // Missing required field` has been in the registry the whole time. Its
only emission site in the tree is `koru_std/testing.kz`, for mock branches.

## Why nobody noticed, which is the actual belief

**Because Zig caught the cases that hurt, and a borrowed diagnostic is
indistinguishable from an owned one until you look at where it came from.** A
missing argument the impl *uses* becomes an undeclared identifier in generated
Zig; a missing struct field on the proc path becomes a Zig struct error. Both are
loud. Both stop the build. Neither is Koru's, and neither covers the case where
the parameter is declared and never read — which is exactly the case a human
would call a bug and a compiler should call an error.

So the surface tested as "mostly working" for ten months, and its gap is shaped
like the host's blind spot rather than like anything in Koru's own design.

**The generalisation: for any rule you believe you enforce, find YOUR emission
site.** Not the failing test — the failing test may be failing for the host's
reasons. A rule with a registry entry, a name, and no emission site is a rule
you are borrowing.

## It was not an oversight — it was written down as ACCEPTABLE

The strongest evidence turned up last, when the new wall turned a green test
red. `510_063_missing_event_param`, in the negative-test cluster, pinned exactly
this program and carried this header:

> `// ACCEPTABLE: Backend Zig error "missing struct field: y"`
> `// (We don't re-implement Zig's type system)`

So someone saw the gap, reasoned about it, decided, and recorded the decision as
a passing test. For ten months the corpus asserted that Koru *should* borrow
this diagnostic.

The reasoning is the interesting part, because it is nearly right. Re-deriving
Zig's type system would be foolish. **But arity is not the host's type system —
it is Koru's own calling convention**, and the two are easy to conflate at the
moment the host happens to catch your case. Delegating it meant inheriting the
host's blind spot along with its coverage, and the blind spot is not a corner:
it is every parameter the impl declares and does not read.

A pinned "acceptable" is a much stronger form of this belief than a missing
check. A missing check is an absence and absences get found. **A documented
decision to borrow is load-bearing: it answers the question in advance, so
nobody asks it again.**

## The libraries had already built it, privately, five times

The corroborating evidence was in plain sight and read as diligence: `std/parser:parse`
hand-rolls *"needs its grammar named"*, `std/store:insert` hand-rolls *"requires a
store name and a row block"*, `std/kernel:init` falls back to a hardcoded shape.
Every library author who cared built this wall privately, one message at a time.
**A rule re-implemented independently by several libraries is a rule the language
does not have** — the duplication is the symptom, and it looks like good error
messages right up until you count the ones that are missing.

## Defaults were never implemented; they LEAK

`b: i32 = 5` parses, and on the proc path it works. It is not a feature.
`Field.type` is literally the string `"i32 = 5"` — the default is the tail of the
type, never split off, pasted verbatim into the generated Zig `Input` struct
where **Zig** applies it. A bare-return subflow has no Input struct, binds args
straight from the call site, never touches the type string, and the default
evaporates.

`auto_discharge_inserter.zig` carries the honest note beside its auto-fill
classifier — `TODO: event-input defaults when the surface supports them on
shapes`. Someone knew. What nobody knew is that the syntax was already *accepted*
and already *half-working*, so the TODO reads as "not built yet" when the truth
is "unbuilt, reachable, and silently type-corrupting": every consumer of
`field.type` sees `"i32 = 5"` where it expects a type.

**An unparsed surface that reaches the host verbatim is worse than an
unimplemented one**, because it works often enough to be used and it poisons a
field that other passes read.

## Open

- Whether `?T` and `= default` should coexist on one field, and what
  `b: ?i32 = 5` would mean. Both are currently type-string tails, so today it
  "works" by accident in exactly one direction.
- What KORU080 must exempt. A comptime transform's shape declares parameters the
  compiler injects — `invocation`, `item`, `program`, `allocator`, `reporter`,
  `source` — and the author writes none of them. Getting that list wrong turns
  the wall into a flood across the whole stdlib, so the exemption is the risky
  half of the fix, not the check.

Related: [[frag-a-fix-installed-at-the-site-that-needed-it]] — same week, same
shape one turn over: there the property existed and was installed too narrowly;
here the property was never installed and the host covered for it.

## The host also hides a DEFECT, not only a missing check

Every case above is a rule Koru does not enforce and Zig does. There is a
second shape that reads identically from the author's chair: a rule Koru does
own, implemented wrongly, whose failure is reported in the host's vocabulary at
a host location.

`std/io:print.ln` lowers its message to a Zig format string, and passed the
author's own braces through unescaped. The build failed inside the host's
`std/fmt.zig` at comptime — in the *standard library's* source, several frames
below any file the Koru author wrote. The defect is entirely Koru's; the
diagnostic is entirely Zig's.

What makes this belong here rather than in a file of its own is that the tell
is unchanged and is still the only one that works: **look at where the
diagnostic came from.** A Koru surface whose misuse is reported at a host
location has either delegated a rule or broken one, and the author cannot tell
those apart — both arrive as an error they cannot act on, about code they did
not write.

The new part is a defect class rather than an enforcement gap:

- **A surface that lowers to a host construct owes the host's metacharacters an
  escape.** Whatever the surface accepts as *data* it must be able to carry, or
  the host's syntax is leaking into the surface's value space. Format strings
  are the first instance found, not the only one available — every place Koru
  splices user text into generated host source is the same question, and each
  one answers it separately today.
