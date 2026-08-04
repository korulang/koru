---
type: belief
id: frag-tor-agentive-surface
provenance: session 2026-07-24 (Lars + Claude + Grok) — the `event` → `tor` rename, language design
ts: 2026-07-24
tags: [koru, language-design, naming, agentive, continuation-branches, pie-etymology]
---

The `event` keyword misleads: it suggests reactive/async listeners, a frame
borrowed from event-driven programming that nothing in the construct actually
carries. What the construct *does* declare is the **agentive surface** of a
named operation — its typed input (the patient, what gets done-to) plus its
named continuation branches (what the doer can hand back as control-flow
possibilities). That second half is the load-bearing half no other language
(known) puts in the signature: the caller's *next step* is typed by the
construct itself. Control flow is pushed into the type system via the
branches living in the declaration, not in the caller's brain.

The rename target is **`tor`**, grounded in the Proto-Indo-European agentive
suffix *-tṛ* / *-tor-. The Sanskrit primary agentive suffix -tṛ (stem -tar-)
forms agent nouns: **kartṛ** "doer/agent" (root √kṛ, to do/make), gantṛ
"goer", dātṛ "giver", mantṛ "thinker." Latin inherits the same formation as
-tor (cognate, confirmed across Indo-European morphology), and it is
productively visible in English/Latin agent nouns everyone already knows:

  **acTOR** — the one who acts
  **creaTOR** — the one who creates
  **moniTOR** — the one who watches over
  **menTOR** — the one who advises/guides
  **dicTOR** — the one who speaks
  **operaTOR** — the one who operates

So `tor` is not an invented coinage; it is the PIE agentive surface worn
flat as a keyword. A `tor greet { name: []const u8 }` declares *who does*
and *what doing looks like from outside* — the kartṛ-role made into the type
system's grammar — and the `proc greet { ... }` is the going-forward
(procedere) that actually does it. The pairing sharpens to noun/verb at the
language's spine: agentive surface + procedural body.

The etymology also names the input cleanly: *kartṛ* (doer) and *karman*
(action/the-done-to) are complementary grammatical case roles in classical
Indian grammar, sharing the root √kṛ. The `tor` declares the doer; the
`{ name: []const u8 }` input declares the karma — what gets done-to. Patient
and agent, separated at the language's surface the way PIE grammar separates
them.

Collision-verified: `tor` does not appear as a standalone identifier anywhere
in the `.kz` corpus or `.zig` sources (case-sensitive and case-insensitive,
zero hits). Safe to take as a keyword.

## Three roots, one mechanic (added 2026-07-24)

German **das Tor** is a gate — Brandenburger Tor — and the gate reading does
independent semantic work: a caller arrives at the tor with inputs and leaves
through one of its **named exits**. The continuation branches *are* the gate's
ways out. (Distinct from *der Tor*, "the fool" — different gender, different
word. Norse **Tor** is a cultural nod, not a structural argument.)

So the name lands three times on the same mechanic from different directions:
agentive (who does), gate (how control leaves), cultural. We did not pick the
word for the gate resonance; it arrived free. That is convergence worth taking,
not overfitting.

## The keyword is FORCED — this is the load-bearing finding

`name { ... }` is character-for-character identical as a declaration and as a
source-block invocation. `210_026` settles it: `renderHTML` is *declared* with a
shape and *invoked bare with a block* in the same file. No lexical rule can
separate them — not qualification, not content-sniffing, not what follows.

The bare form is therefore a scarce resource with exactly one meaning available,
and Koru already spent it on the config syntax (`flag.declare { }`,
`std/build:requires { }`, `std/store:stored { }` — 57 sites). Given that ruling,
declarations MUST carry a marker. **The keyword is not a wart we failed to
remove; it is the price of a syntax judged more valuable.**

Type-directed disambiguation was explored and rejected: every bare-invocable
form declares an opaque-capture parameter (`Source`/`Expression`) in its own
shape (14/14), so resolution *could* decide. It was declined because it makes
declaration-vs-invocation import-sensitive — the C-typedef / Scala-implicit
hazard class, where an upstream library adding a `Source`-taking event silently
converts a local declaration into an invocation. Koru's version would have been
milder than C's (uniform AST, resolution-level not parse-level, loud walls
available) but the category is one with a long body count, and the win was
aesthetic.

## Explicit `pub tor`, not hybrid `pub jump` (ruled 2026-07-24)

`pub tor jump { }` / `tor jump { }` — the keyword appears at every declaration.
The hybrid (`pub` alone marking public declarations, since `pub proc` is already
an error) was live and rejected for three reasons:

- **It hides the word from the audience that needs it.** Public declarations are
  what reach the tutorial, the learn pages, and every talk slide. Under the
  hybrid, `tor` never appears there — the central construct's name absent from
  the language's face. (~50/50 public/private, so it is not even rare.)
- **`pub` stops being a modifier.** Explicit keeps two orthogonal words
  composing: `tor` says what, `pub` says who-can-see. The hybrid makes `pub` a
  second declaration keyword whose meaning depends on the absence of another.
- **Forward compatibility, the one refused trade.** The hybrid works only
  because "only events can be public" is true *today*. The moment types, stores,
  or anything else becomes exportable, `pub jump { }` is ambiguous about what it
  declares, while `pub tor` / `pub type` / `pub store` compose forever.

`pub tor` together is redundant-by-construction and should be walled with a real
diagnostic, never silently accepted.

## Open

Phase 2, internal and behaviour-invisible: whether `EventDecl` / `event_decl` /
the `"event"` AST-JSON field / `<name>_event` mangling also rename, or keep
their spelling as an implementation detail. Also open: the user-facing prose on
korulang.org, and whether test-directory names carrying `_event_` follow.
