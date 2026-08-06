---
type: belief
id: frag-a-dead-attempt-standing-beside-a-live-system-multiplies-it
provenance: the 2026-07-31 interpreter reckoning — "we have two or three attempts and I'm confused" resolved to ONE live layered system (interpreter.kz + runtime.kz) surrounded by a caller-less src/interpreter.zig whose header claimed consumers it never had, a third dead copy of the same expression evaluator, and a TUI whose comments promised a REPL its body never contained
ts: 2026-07-31
---

# A dead attempt standing beside a live system multiplies it (belief)

The felt state "we have two or three interpreters" was not an architecture
problem. It was a depiction problem: one live system, plus artifacts that
*claimed* to be it.

Each ghost multiplied the count a different way. A caller-less core whose
header names consumers it doesn't have (`src/interpreter.zig` claimed the
frontend and the runtime interpreter; grep found only its own benchmark). A
dead duplicate of a small evaluator, invoked by nothing. Comments promising
behavior ("Run a REPL against the program scope") the body never implements.
None of these executed a single instruction in anger — yet together they
turned one interpreter into "two or three" in the mind of the language's own
author.

The costs are real even though the code is dead: orientation cost every time
someone asks "which one is real," a compile cost carried in every build, and —
worst — a *decision* cost: a rewrite ruling was partly justified by properties
of the ghosts, not the live system.

The move: when a subsystem feels multiplied, inventory the callers before
theorizing about the versions. Deletion of the caller-less is not cleanup, it
is the answer to the confusion. After the 2026-07-31 deletion, "which
interpreter do we have" has one answer by construction.

Related: a failure that looks like success is unfalsifiable — a header that
narrates consumers is the same disease as a comment that narrates correctness;
grep, don't believe.

## The fourth cost, found 2026-08-06: the ghost keeps the defects the fix removed

The three costs above — orientation, compile, decision — all assume the ghost is
*inert*. It is worse than inert. A dead copy is unreachable by the fix that
repairs the live one, and unreachable by every test, so it does not merely sit
there: **it preserves, indefinitely, the exact defects that were corrected next
door.**

`koru_std/build_defaults.kz` is the same disease as the caller-less interpreter
core, down to the same tell: its header claimed `build.kz` imports it, and grep
across `koru_std/`, `src/` and `tests/` found nothing that names it. But where
the interpreter ghosts merely inflated a count, this one still carried both
defects that had been fixed in the live defaults — the comma separator and the
wrong backend binary — because nothing could reach it to fix them and nothing
could fail to reveal them.

That converts the ghost from an orientation cost into a **teaching** cost, which
is strictly worse because it is *load-bearing on a future reader*. Someone greps
for the construct, finds the dead spelling, and copies it. The ghost is not a
stale answer to "which one is real"; it is a confident wrong answer to "how is
this written", and grep ranks it exactly as highly as the truth.

What follows, beyond the existing "inventory the callers" move:

- **A dead copy's content is not neutral — audit it or remove it.** Deadness is
  what protects a defect, not what makes it harmless. The reflex "it's not
  running, so it doesn't matter" is the error; running is not how a copy does
  damage.
- **When a fix lands in one of two copies, the second copy's deadness is the
  reason to check it, not the reason to skip it.** The live one had a test; the
  dead one had nothing, so it is the copy more likely to still be wrong.
- **A wall beats an audit here.** The comma this ghost carried is now refused by
  PARSE007, so that particular wrong spelling cannot survive anywhere the parser
  reaches — but it survived in this file precisely because the parser never
  reaches it. A wall does not cover dead code, which is the argument for not
  keeping any.

Related: `frag-a-fix-lands-in-one-lowering-path` covers two *live* copies, where
the second keeps its old cost silently. This is the degenerate case — the second
copy is not merely unfixed but unreachable, so no measurement can ever surface
the divergence.

Open: whether this file should exist at all is not mine to settle; its contents
are corrected so it cannot mislead, and the deletion question is flagged.
