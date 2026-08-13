---
type: belief
id: frag-two-parse-paths-feed-one-dispatch
provenance: 430_055 — prose-is-not-an-invocation, found live by kopium-headless/live.k
ts: 2026-08-13
---

# The interpreter's parse surface is two parsers feeding one dispatch, so interpreter-source validation must gate on the invocation AFTER parsing (belief)

An English sentence containing parentheses parses as a well-formed invocation
whose "name" is the sentence. `std/runtime:run` had parked the fix for this in
the lightweight parser ("the check belongs in flow_parser, before the scope
lookup ever runs") — true and insufficient, because the interpreter does not
have one parse door. It has two: the lightweight `flow_parser` fast path, and a
**fallback to the full compiler parser** when the fast path fails. A validation
fixed in one door leaves the other open; 430_055 proved it by staying red.

So the rule that stuck: any validation of interpreter-supplied source must gate
on the **parsed invocation**, after either parse path and before the scope
lookup — not on a single parser's willingness to accept the text. `event-denied`
says "that verb is real but not yours"; `parse-error` says "that was not Koru".
Handing the first to a caller who did the second teaches an LLM the wrong lesson
about what went wrong — which is exactly why the agent loop feeds dispatch
outcomes back.

What would correct this: the full-parser fallback being removed from
`std/runtime:run`, so a single parser owns the gate again — then the belief
"two paths feed one dispatch" is stale and gating-in-parser alone is honest.

Related: [[frag-a-fix-lands-in-one-lowering-path]] — a fix confined to one
path of a two-path surface looks landed while the other accepts the input.