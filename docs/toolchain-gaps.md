# Toolchain Gaps & Friction — consumer-reported

Found by `koru-rive` (a `.riv` decoder/player exercising Koru hard, 2026-11-16,
turns ~8–176) plus arbiter-seat notes. Each entry: what was hit, why it
mattered, what the fix probably is. Ordered roughly by how much session time
each cost. These are friction/gap reports, not rulings — several may already
be known; filing them so they don't get re-derived per consumer.

## 1. Emitted-Zig diagnostics name the wrong file

`error: unused local constant` points at `output_emitted.zig:2620`, not the
`.kz` source site. Every emission-strictness failure costs a detour through
generated code to map back. Fix direction: emitted diagnostics should carry
the source span (or at least the `.kz` line) alongside the zig line — a
`// src: index.kz:2613` marker per emitted decl would collapse the hunt.

## 2. Unused bindings are hard errors in emitted Zig

`const gapU: f32 = …` declared-but-unused → emitted-zig
`error: unused local constant` → whole build fails. Reasonable strictness,
but Koru should either auto-discard provably-unused locals or diagnose at
the `.kz` level with a teaching message ("unused binding — prefix `_` or
drop it"). Hit once directly (arbiter rebuilt `inspect3`), hit repeatedly by
t47.

## 3. Integer-width coercion is a recurring tax

`usize`/`i64`/`u64`/`u16` mismatches between prop accessors, literals, and
`{d}` print formats break emission repeatedly:

- `propU` returns `u64`/`i64`; `{d}` print wants a specific width → needs
  `@intCast`/`@as` guessing.
- `abIdx: i64` vs `usize` object indices → `const sm`/`@as(usize,@intCast())`
  comparisons broke emission twice.
- `p.key` `u16` vs literal/`be16` return width in `hmtxAdvance`.

Each was a one-line fix but there were ~6 of them. Fix direction: Koru int
types should coerce like the source language promises (or the prop accessors
should return the width the consumer expects, documented).

## 4. Optional/unwrap and shadow-capture emission breaks

`sfntFind(...).?` unwrap, unused-var patterns, `o,i`→`to,ti` shadow-capture
renames — all broke emission in `emitTextDraw`/`collectDrawsText` before
compiling. Same class: the emitter produces zig that its own frontend
would reject; each needs an emitted-line read + manual cast/rename.

## 5. Brace/`else` adjacency and inline-surgery fragility

Unbraced `if…else if` chains break zig's `} else` adjacency rule; block
surgery (nested `emitOps` inside a helper) twice broke brace balance and
once clipped `owningArtboard` into a comment — silently changing semantics
(a Triangle leaked into every section). The last one is the dangerous kind:
emission succeeded, output was wrong. Fix direction worth considering:
emitted zig should be re-parsed/verified before linking, or block-structured
edits should be safer by construction.

## 6. `for` is top-level-only (KORU010)

`for` loops are illegal inside tor bodies and chain arms. Stream consumption
therefore *must* use continuation-yield tors (`! op Rec` / `| done`) — a real
design, but the teaching surface doesn't show it early enough; t47 spent
several turns discovering the wall. Fix direction: document the yield
pattern as THE iteration idiom in the tutorial/by-example corpus, with a
nested-consumption example (yield inside a `| arm`).

## 7. Yield-inside-branch-arm nesting unclear

`! o` / `| done` inside a `| loaded r` arm kept hitting KORU010 subflow
indentation rules; no corpus example of a yield continuation nested inside
another arm exists. Whether it's expressible at all is unverified — the
workaround hunt produced the `.kz` package route instead. Needs either a
ruling (expressible → document the shape) or a pinned gap.

## 8. ~~`match` is not a surface expression~~ — RULED: design, not a gap

`match o.kind` parses as a tor call → `unknown tor 'kztest:match'`.
**Lars ruling (2026-11-16):** `match` doesn't exist *by design* — Koru has
no enums or tagged unions yet, so there's nothing for `match` to dispatch
over. The multi-branch surface is `cond`. Refiled as DOC, not DESIGN-gap:
the consumer-pattern docs should show `cond` for kind-dispatch (9 op kinds
in the Rive probe) so the next consumer doesn't grep for `match`.

## 9. `.kz` host-embedding `~` prefix friction

Every Koru construct in `.kz` needs `~` (`~import`, `~pub tor`, `~var`).
Bare identifiers in Koru bodies resolve as tor calls — `~var h: i64` is
legal module state but `h` bare → `unknown tor 'kztest:h'`; module vars
may need `$mod.` qualification (unverified). Undiscoverable without
corpus archaeology. Fix direction: a `.kz` syntax cheat-sheet in the
tutorial + better error text ("did you mean `$mod.h` or a tor call?").

## 10. `.k` vs `.kz` capability split is invisible

`~pub tor`/`~proc|zig` are `.kz`-package-only — pure `.k` files reject `~`
(PARSE003). The collection-return ABI (`-> [][:0]u8` across a zig-proc
boundary) was only testable after discovering this. Consumers can't tell
from the file extension what language level they're in. Fix direction:
docs + maybe a diagnostic naming the package requirement.

## 11. Sentinel-terminated collections (`[:0]T`) — spelling is a trap

`-> [][:0]u8` means list-of-sentinel-strings, not "list returning a
sentinel buffer" — signature confusion cost a compile cycle. And `[:0]u8`
requires NUL-termination: buffers ending in `\n` fail; the
`[]u8 → [:0]u8` cast form (`z[0..z.len-1 :0]` or pointer-cast) is
undocumented. Fix direction: one doc example of the sentinel-return
pattern end-to-end.

## 12. Chain result-binding forms are tribal knowledge

`|> tor(...) : out` mid-chain → SHAPE002. `| out` pipe-label is the legal
form. `| loaded r` binds only within its arm — downstream calls must chain
inside the same arm. Three separate discoveries, each a compile cycle.
Fix direction: a "chain binding" section in the tutorial showing the
three legal forms side by side.

## 13. Corpus has no consumer-pattern examples for streams/collections

`args.k` has `-> [][:0]u8`, `path_probe.k` has `| surf s`, but nothing
shows: yield-consume a tor stream inside another arm · return records
across a zig-proc boundary · dispatch on a record field. Every one of
these was reverse-engineered from parser errors. Fix direction: a
`by-example/` consumer-patterns page — the corpus is rich on language
features, thin on "how do I actually build a consumer."

## 14. `std.debug.print` → stderr silently

All diagnostic dump output goes to stderr; `2>/dev/null` kills it with no
warning. Cost ~6 turns of t47 hunting a "dump-mode gate" that was actually
a 0-byte binary + stderr redirect. Minor, but for a teaching surface:
dump/inspect modes should document their output channel, or offer a
stdout flag.

## 15. No `cond`/block-bodied Koru tor examples in corpus

Every `~pub tor` in `koru_std` pairs with `~proc|zig`; no example of a
`name = <chain>` tor body surfaced (though compile-test shows `~t = <chain>`
is legal). If-expression branches holding chains and `~var` mutation inside
bodies were still unverified at filing time. The dispatch problem (9 op
kinds) is exactly where `cond` earns its keep — and per the ruling above,
`cond` (not `match`) is the surface to teach.

---

### Notes for whoever fixes these

- Items 1–5 are all "emitter produces zig the frontend would reject, or
  diagnostics don't map back" — arguably one root cause: the emitted-zig
  boundary needs source-span provenance.
- Items 6–9, 15 are syntax-surface gaps — each has a minimal repro in
  `/tmp/kztest`-style scratch or was pinned by compile-test this session.
- Items 10–13 are documentation/teaching-surface gaps — cheapest fixes,
  highest leverage for the next consumer.
- Item 14 is minor but bit hard because it looked like a language gate.
