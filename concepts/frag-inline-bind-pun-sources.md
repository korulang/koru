---
type: belief
id: frag-inline-bind-pun-sources
provenance: surfaced building koru-libs/vaxis (`! draw win |> app()`); diagnosed + fixed 2026-07-22 (pin 210_157)
ts: 2026-07-22
---

# The inline-bind pun has TWO source classes, and their scope-timing differs by WHERE the value is produced (belief)

The inline-bind pun (`ast_transform.zig` `punContinuationBinding`) fills an
invocation's unfilled input field from an in-scope binding of the same name —
synthesizing the explicit `field: field` the author omitted. No-shadowing makes
the in-scope match unique, so it's unambiguous. Two kinds of binding can feed it,
and the correct behaviour is NOT the same for both:

- **Return bind** (`producer(): x |> consumer(...)`) — `x` is produced BY the
  invocation the pun sits on (`cont.node` is the PRODUCER). The consumer is a
  SEPARATE child continuation. `x` must NOT pun into `producer` itself, so it
  enters scope AFTER the node's own fill. Reference: 210_154 (green).
- **Branch / effect payload** (`! emit x |> consumer(...)`, `| ok x |> consumer`)
  — `x` is produced UPSTREAM (the emitting tor, or a prior branch). Here the
  payload binding and its consumer sit on the SAME continuation
  (`| emit x => INVOKE consumer`), so `cont.node` is the CONSUMER, which may
  legitimately pun the upstream payload into its own args. The payload must be in
  scope BEFORE that fill. Reference: 210_157 (the pin this belief closed).

So the rule is: **seed a branch-payload binding into scope BEFORE filling the
continuation's own node; add a return bind AFTER.** The single knob is *who
produces the value* — an upstream payload is fair game for the same continuation's
consumer node; a value the node itself produces is not.

## Why it was wrong before

The desugar collected the branch payload (`cont.binding`) in the same late step as
the return bind — after the node fill. Correct for return binds, wrong for effect
payloads: the payload's own consumer node was filled before the payload existed in
scope, so the field stayed unfilled and the binding then read as unused
(`KORU100 unused binding`). The framing in the original pin ("effect payloads
aren't pun SOURCES") was itself wrong — they were always collected; the miss was
purely the scope-timing.

## The tell that this was a bug, not a design choice

The compiler already ADVERTISED the effect-payload pun while failing to deliver it
implicitly. Two spellings worked the whole time, proving the binding was a live
source: the bare-arg form `consumer(x)` ran, and the explicit `consumer(x: x)` was
rejected as a redundant label ("'x' already puns to 'x'"). Only the fully-implicit
`consumer()` / omitted-field form missed. One pass promising the pun and another
refusing to apply it is an internal contradiction — the argument for fixing rather
than pinning-as-intended.

## Scope / not-yet

- The fix rides the same `cont.binding` code path that carries BOTH effect
  payloads (`! emit x`) and terminal branch payloads (`| ok x`) — the parser
  assigns the branch binding kind-agnostically, tracking effect-vs-terminal
  separately. So the pre-fill seeding covers terminal branch payloads by the same
  mechanism; the effect-payload case is the one SHOWN and pinned here (210_157).
- Unrelated pun frontiers stay where they were: a required param with no matching
  binding (210_155) and a name-match/type-mismatch (210_156) are still deferred
  reds — they error at the Zig backend boundary, awaiting the general
  arg-validation pass (pure-`.k` scoped). This belief does not touch them.
- RULING 3 (a transform-result struct — `SiteResult` — must be field-accessed, not
  punned whole into a string param; KORU038) is orthogonal and unchanged.
