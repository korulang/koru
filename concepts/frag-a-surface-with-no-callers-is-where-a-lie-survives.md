---
type: belief
id: frag-a-surface-with-no-callers-is-where-a-lie-survives
provenance: found 2026-08-07 while sweeping four repos for a forbidden spelling. koru_std/net.kz turned up as a stdlib module whose five tors all returned fabricated successes; measuring its blast radius before touching it revealed it had zero callers anywhere, which is the same fact that explains why it lasted
ts: 2026-08-07
---

# A surface with no callers is where a lie survives

`koru_std/net.kz` declared a socket vocabulary and implemented none of it. Every
one of its five tors returned a fabricated success: `tcp.accept` handed back a
connection id of `1`, `tcp.read` returned the same hardcoded HTTP request string
on every call, the rest printed "would…" and reported done. A program built on it
compiled, ran, logged plausibly, and served the same invented request forever.

That is the banned shape stated exactly — a substitute output standing in for a
path that was never built — and it sat in the standard library long enough that
nobody remembers writing it.

**The reflex when finding it is to ask who broke. The useful question is the
opposite: nobody did, and that is the finding.** A grep across all four repos
returned zero callers. No program imported it, so no program was ever misled by
it, so no failure ever pointed back at it. Its harmlessness and its longevity are
the same fact.

Invert that and it becomes a search strategy. A lying surface **with** callers
gets found fast: someone builds on it, the fabrication contradicts reality, and
the bug report arrives. A lying surface with **no** callers has no such clock. It
is not slowly discovered — it is permanently undiscovered, and it stays exactly
as wrong as the day it was written while everything around it moves on. So the
place to hunt for fabrication is not the busy code; it is the code with no
inbound edges: showcase modules, demo stubs, "simplified for now" surfaces,
anything whose header says it was written to make something else look finished.

**Zero callers is also what makes it cheap to fix, and that is the trap.** The
absence of consumers reads as permission to delete. Deleting is the wrong repair
here, because the name is the part that does damage: `std/net` is what a person
reaches for, and a module that is merely gone answers them with
`module not found` — true, and useless. The rule already says what to do instead:
when the real path is not ready, **fail loudly and carry an address.** The
declarations stay so the refusal has somewhere to live; the bodies refuse at
compile time and name the real surfaces (`koru/curl` for a client, Orisha for a
server). Importing still succeeds — the refusal is positional, firing where a tor
is *used* — so the module can be named, read, and learned from without ever
running a fiction. Pinned both directions: 670_001 (use refuses, and the refusal
names the address), 670_002 (import alone still builds).

One honest gap in the repair: the refusal is a Zig `@compileError`, so it reaches
the author as a raw backend error rather than a Koru diagnostic. It is loud and it
teaches, which beats lying, but it does not yet meet the bar that every stdlib
refusal speaks Koru.

Related: [[frag-a-dead-attempt-standing-beside-a-live-system-multiplies-it]] (the
same disease in the other direction — there the dead thing has callers and steals
them; here it has none and hides).
