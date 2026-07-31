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
