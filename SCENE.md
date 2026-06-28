# SCENE.md — Koru

> **Read-many, write-rarely.** You read this on every walk; you almost never
> edit it. The *existing* scene — what the repo actually is — moves fast and
> lives; read that from the code, fresh, every time. This file is the *ideal*
> scene: slow, sticky, mutated only as a deliberate walk-level act.
>
> **Scouts get the ideal user, NEVER this file.** The scene is felt and stays
> with the walkers. A subagent is handed the distilled ideal user, never
> `SCENE.md` itself.

## The north star — no compromise

Koru is the language that **refuses the tradeoff**. Every time someone lays an
"it's X *or* Y" on the table — performance or readability, correctness or
velocity, safety or ecosystem, power or learnability — Koru's answer is *have
both*. Not as a slogan: as the design discipline. The whole field is built on
tensions you're told to choose between; Koru is the bet that **most of those
tensions are failures of design, not laws of nature, and that the right design
dissolves them.**

That defiance is the spine. The twelve-year-old's version: someone names a
tradeoff and Koru says *"no — here, you can have both, and get out."* And means
it — because it can show it.

## The feeling

Koru is the one everyone secretly wishes they'd thought of first — you reach for
it without thinking, it does exactly what you meant, and everything else suddenly
looks like it's trying too hard. Unembarrassed certainty: this is the good one.
The website already swaggers the energy — *"The Hyper-Performant … Phantom-Typed
Auto-Disposing Monadic Event Continuation Language"* — a pile of everything. The
north star is what gives that pile a spine: it isn't "look how much we crammed
in," it's "we refused to give any of it up."

## The beds — one garden, two halves of "no compromise"

### Worthy — great on every axis at once

Fast *and* safe *and* efficient *and* ergonomic. Each "and" is a tradeoff the
field swears you can't have: top-tier runtime performance with resource-safety
**stronger than Rust's**, paid for in neither a runtime nor friction. The merit
bed is itself a refused compromise — not one excellence, but the ones you're told
are mutually exclusive, together.

### Chosen — don't rewrite, assimilate

Bring your battle-tested C or Zig library *as-is*, and Koru makes it more
resource-safe than a Rust rewrite would — **without the rewrite**. This is the
bed that decides whether the dream is real, because it dissolves the tradeoff the
research says *kills* worthy languages: **ecosystem maturity vs. safety**. You
don't choose between C's proven libraries and compile-time guarantees — you take
both. The messaging follows from the move: *don't rewrite, assimilate.*

**`koru-libs` is this bed's worked ground** — where "assimilate" gets proven,
package by package, showcase by showcase. (sqlite3 already wraps C SQLite behind
phantom obligations: `conn[opened!]` — the compiler will not let you forget to
close it.)

## What it says no to

The no-compromise language has two hard refusals, and they guard its own failure
modes:

- **No unearned claim.** "Have both" that isn't *shown* is hype — and hype is the
  straight road to most-admired-never-used. Every "faster than / safer than"
  ships only when demonstrated apples-to-apples. The showcase is the proof; the
  claim waits for it.
- **No compromise is not "hoard both sides."** Refusing a tradeoff means finding
  the design that **dissolves** it — the way *assimilate* dissolves
  ecosystem-vs-safety — never bolting both halves on and calling it done.
  Feature-maximalism wearing the no-compromise badge is the C++ trap, and this
  scene rejects it: the spine is a principle, not a pile.

## Tending log

- 2026-06-27 — planted as a seed (feeling only). — walk (Muse)
- 2026-06-28 — grew the spine. North star "no compromise / dissolve the tradeoff"
  co-derived; worthy and chosen beds named (chosen = "don't rewrite, assimilate",
  worked ground = `koru-libs`); two refusals encoded. Beds floated from the
  ambition float (winners vs worthy-losers, blind pair) crossed with the
  koru-libs assimilation insight. — walk (Muse)
