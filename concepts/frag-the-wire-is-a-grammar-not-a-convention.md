---
type: belief
id: frag-the-wire-is-a-grammar-not-a-convention
provenance: kopium R2 rung, 2026-08-17 — the wire parser landed as parse.wire in koru_std/runtime.kz with 430_059..430_062 green and the 440 bridge family intact
ts: 2026-08-17
tags: [koru, kopium, wire, grammar, derived, interpreter, agent-channel]
---

# The wire is a grammar, not a convention (belief)

Until R2, the language a model speaks to a Koru interpreter existed only as
prose: prompt text saying "one invocation, no chains, quoted strings," with
the general flow parser behind it accepting shapes the prompt forbade. A
convention the parser does not enforce is not a channel — it is a hope.
kopium's live turn 6 measured the hope: an English sentence parsed as an
invocation (430_055), and the refusal came back with the wrong meaning.

The ruling the R2 rung lands: **the wire is a restricted grammar, derived
from the register block, with no general-expression escape hatch.** One
invocation per turn; `verb(field: "value")`; nothing after the closing
paren. Prose, chains, truncated strings refuse at *parse* time, with
diagnostics written to be read by the model that emitted them.

The load-bearing split, the one that keeps the meanings honest:

- **parse-error** answers "that was not Koru" — the grammar's verdict.
- **event-denied** answers "a real verb that is not yours" — the scope's
  verdict, at dispatch.
- **validation-error** answers "that field is not on this verb" — the
  signature's verdict, at dispatch.

Collapsing any two of these teaches the agent the wrong lesson about its own
mistake, and the agent's next turn is built from the lesson we hand it.

## Open questions

- Per-field checking at parse time (naming the verb's real fields in the
  refusal) is available from the same comptime scope table — deferred, not
  rejected.
- `430_055` pins the same prose-refusal against the *general* interpreter;
  whether `flow_parser` itself tightens is a compiler-core question, Lars's
  call.
- The derived grammar *render* (the prompt bytes from the same table) is
  the sibling surface: prompt and enforcement as the same bytes, completed.
