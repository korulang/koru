---
type: belief
id: frag-the-thread-binds-by-type
provenance: ruled with Lars 2026-07-27 while collapsing koru-libs/curl's async chain; pin 210_176
ts: 2026-07-27
---

# The point-free thread binds by TYPE to the one unfilled parameter — it needs no name and no position (belief)

`frag-pointfree-threads-the-branch-left` settles which branch threads: the sole
survivor, by arity. This settles **where it lands**.

**The rule.** The thread fills the *unfilled* parameter whose type it matches.
Written arguments narrow the field first; then the type decides. Exactly one
candidate binds. Zero or several is a compile error naming them. Pin: 210_176.

Partial fill falls out rather than being added. `send-mail { to, subject, body }`
is three parameters of identical type, and `|> send-mail(to: "a", body: "b")` is
still unambiguous, because two are written. Writing none of several same-typed
parameters is the genuine ambiguity, and that is the error.

**Optional parameters are never candidates**, because an optional is never
*unfilled* — omitting it is already a complete call (`multi.new()` against
`{ allocator: ?std.mem.Allocator }`). This is not an exception carved out; it is
what "unfilled" means. It also supplies, for free, the slot marker that was
rejected as unprincipled: making a parameter optional is a visible way to say
*this is not the thread*, so no `[thread]` annotation is needed.

## The belief this repudiates

Implicit argument binding was believed to require a distinguished NAME. The one
shipped instance of it — the implicit expression slot, `expr: Expression`
(110_023/024/025) — has one, and every candidate considered for the thread was a
search for its equivalent: `subject`, `self`, `this`, `it`, and a glyph. The
name was carrying no weight. 110_025 already states the selection is by "the
parameter's TYPE and NAME", and the type alone is what disambiguates, because
`Expression` appears at most once in a transform's signature. So the thread rule
is 110_025 with one condition removed, not a second mechanism beside it.

The related name-based implicit fill described in
`frag-inline-bind-pun-sources` — filling an unfilled field from an in-scope
binding of the same NAME — is superseded for the thread. That mechanism already
had a pinned misfire: 620_006 (KORU038) is a wall built because the binder
`text` punned into a `text: string` parameter while holding a result struct. A
type-matched thread cannot make that mistake; the wall stops being load-bearing.

## Why each candidate failed, so none is relitigated

- **A reserved slot name** collides with domains that already own the word.
  `pcre2:find.all { re: *Regex, subject: []const u8 }` declares `subject` for
  the string being matched — and it is the one parameter that is *not* the
  thread. `send-mail { to, subject, body }` is the same hazard in a second
  domain.
- **`self` / `this`** claim the value is a receiver. Koru has no receivers, no
  methods, no objects; `bump(this: 5)` is a category error. `self` additionally
  means method-receiver throughout the Zig half of every lift.
- **`it`** is the best pronoun of the three and collides with nothing, but it
  would live at the DECLARATION site, where a pronoun reads as a parameter
  nobody bothered to name. It is a use-site word (Kotlin's) in a position that
  only ever reads.
- **A glyph** answers both the collision and the pronoun problem, at the cost of
  the written-out site. Not wrong; simply unnecessary once the type carries it.
- **Binding to the FIRST parameter** — attractive because every threadable
  parameter across curl, raylib, pcre2, vaxis and all 22
  `{ ctx: CompilerContext }` declarations in koru_std already IS first, with no
  convention imposed. Rejected because it would make declaration order
  load-bearing for the first time in the language. 110_025 is the standing wall
  against exactly that, built for the expression slot, with the stated reason
  that position-selection "would silently break any transform that declares
  `expr` anywhere but first". Koru stays order-free.
- **Branch-name matching** (the mechanism the flat `analysis` pass runs on
  today, and the one described in `a-pyramid-is-a-pipeline-hand-unrolled`)
  couples placement to the branch name, which is the volatile side — a branch
  may be renamed freely, a signature may not. It also only ever works when two
  independently-authored modules happen to share vocabulary. `multi.start`
  produces `| started`, `await` takes `p`; there is no name to coincide, and
  naming curl's parameter `started` would be a lie about what it holds.

## What this does NOT touch

Selection is unchanged: the sole unclaimed branch threads, by arity, never
polarity (`frag-pointfree-threads-the-branch-left`). Claiming is unchanged.
Written argument punning is unchanged and stays mandatory — `b(m)` binds by
name, and position means nothing there, which is what 210_094/095/096 wall.

The bright line is **written versus not written**: what you write binds by name,
what you do not write binds by type. Both rules sit on the correct side of it.

## Open

The rule is ruled and pinned; the compiler side is not built. What "type
matches" means precisely is where the remaining design lives — phantom-state
requirements (`*Multi<empty!>` arriving at `m: *Multi<!empty|!open>`) are an
assignability question the obligation checker already answers, but numeric
coercion and `string` versus host slice types are not yet settled.

Also unruled, and adjacent rather than downstream: whether `|>` on a void step
becomes illegal in favour of statement listing, and whether naming a value
(`: m`, or destructuring `{ a, b }`) ends the thread. Both were reasoned through
on the same day and neither was ruled.
