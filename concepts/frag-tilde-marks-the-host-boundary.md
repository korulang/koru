---
type: belief
id: frag-tilde-marks-the-host-boundary
provenance: ruled while orienting on the budgeted interpreter / resource bridge / shell direction; settles the design question 430_047's TODO had carried open since 2026-05-15. Corrected 2026-08-07 after Lars asked whether the interpreter still accepted `~` and the answer turned out to be "on one route it is mandatory". Evolved later the same day by a four-repo sweep for the forbidden spelling: the corpus came back clean, but the enforcement did not — the compiler half of the rule had no pin, and the interpreter's flow parser still documents and unit-tests the tilde as optional beneath every guarded door. Evolved 2026-08-12 by the corpus-presentation sweep: the by-example generator embedded raw `.kz` verbatim into every context-facing artifact, teaching `~tor`/`~import`/`~hello()` as the surface for months — a door that taught the negation; the generator now strips the marker at presentation and the corpus sources' comment prose was swept
ts: 2026-08-16
---

# `~` marks the host boundary, and nothing else

The tilde has exactly one job: it tells a reader — and the parser — that the
line it opens is a **Koru form embedded in host text**. That is why it is
absolute in `.kz`, where Koru and Zig share a file and something has to say
which language the next line is written in.

It follows that in a context which is *already* pure Koru, the tilde marks
nothing. It is not shorthand, not emphasis, not an optional flourish — it is a
wart left behind by the boundary it used to describe. `.k` files established
this first: they are pure Koru, they declare `tor example.write` untilded, and
they reject the tilde outright.

The ruling (Lars, 2026-07-24) extends that from the file to **every pure-Koru
context**: interpreter source, the shell prompt, and the wire. What the
interpreter accepts is `ping()`. `~ping()` is rejected — an error, not a
tolerated alternative.

**The scan skips string literals, and that is not a concession.** `~` inside a
string is data — `open(path: "~/notes.txt")` is the most common path on a unix
machine, and a rule that made it unexpressable would be wrong, not strict. The
axis is code position vs. data, never "contains the character."

## What this file got wrong: "the single choke point"

The original entry announced the wall as finished and named its location as
*the single choke point, since `std/runtime:run` delegates there*. That claim
was never true, and it is the reason it survived a year: it enumerated the
routes that **execute** and mistook them for the routes that **exist**. A
fourth public entry point — parse-then-eval, split across two tors — predated
the wall by six months and never had it.

The severity is the part worth carrying. That path did not merely *tolerate*
the forbidden spelling. It **required** it. Under it, `greet(name: "World")`
— the only legal spelling of interpreter source — failed, and `~greet(...)`
ran green. A reader who learned the language from that route would have
learned the inverse of the rule, and been rewarded for it by a passing test.

The mechanism is worth naming because it will recur wherever a subsystem
borrows another's machinery. That entry point was not written as an
interpreter path; it was pasted from the **compiler's** source-file parsing
wrapper, and it brought that parser's assumptions with it. The compiler's
parser answers "host-embedded or pure?" by reading the filename extension —
correct for files, and meaningless for a string that has no file. Callers with
no file therefore had to invent one, and the invented extension silently
answered a question interpreted source does not have. There is no dialect for
interpreted source; the code had one anyway, because a parameter it copied
implied one.

Two things follow, and they are the durable part:

- **You cannot enumerate a rule's entry points by reading the subsystem that
  owns the rule.** The missing route was owned by the interpreter and written
  by the compiler. Enumerate instead by asking who can reach the executor.
  This is [[frag-a-watcher-off-the-normal-path-is-not-a-wall]] with the
  topology hidden one module further away than usual.
- **An unguarded path is not the neutral absence of a guard.** It runs
  whatever its borrowed machinery believes, and that can be the negation of
  the rule. "Unwalled" and "permissive" are not synonyms; the honest question
  about a missing wall is not *what does it let through* but *what does it
  demand*.

The residue is in code rather than here: the parse entry point takes no file
name at all, so the question that produced this has no parameter left to be
answered by accident.

## The door was closed; the room still disagrees

Swept the same day, and the closing claim above needs qualifying. Fixing the
fourth door fixed *a door*. One layer beneath every door, the interpreter's own
flow parser still documents the tilde as optional, strips it when present, and
carries a unit test asserting that acceptance — named for the behaviour it
protects, running on every `zig build test`.

So the rule is **guard-shaped, not machinery-shaped**. Each executing entry
point calls a check before dispatching; the thing they all dispatch *into*
believes the opposite. Every current route is walled and the corpus measured
clean, which is exactly why this is worth writing down instead of trusting:
the arrangement is correct today and self-repealing tomorrow. The next caller
to reach the parser directly does not *forget* the wall — it never meets one,
and inherits a subsystem that treats the forbidden spelling as ordinary. That
is the fourth door's topology reproduced one level down, with a green test
holding the old belief in place.

The general form, and the reason this outlives the tilde: **a guard at each
door is not the same as a rule in the room.** Guards enumerate; rules hold. A
rule enforced only by enumeration is bounded by whoever last counted the doors
— and this fragment has already been wrong about that count once.

Being unpinned is the same defect in the other direction. The `.k` half of the
rule ran a year enforced by the parser and asserted by nothing; its diagnostic
existed at exactly one site, so any refactor of the boundary would have taken
it away silently, with a green board. Pinned now (210_203), quoting the
diagnostic's own words rather than its code, so rewording the wall is also a
red. The interpreter half had pins throughout; nobody noticed the compiler half
did not, because the *rule* felt covered — which is what a half-pinned rule
feels like from the inside.

## The corpus-presentation door (2026-08-12)

The enumeration gained a door that had been teaching the negation for months:
the by-example generator (`scripts/lib/corpus.js`) embedded raw `.kz` —
code *and* comment prose — verbatim into every context-facing artifact
(`koru-by-example.md`, `docs/by-example/*.md`, the skill files). An LLM or a
reader met `~tor hello {}`, `~import std/io`, `~hello()` as the language's
surface spelling — the exact inverse of this rule, rewarded with a green
board because nothing executed those files. Measured before the fix: 115
tilde-lines in `koru-by-example.md`, 412 in the by-example shards, 10 in
skills.

The fix is a presentation rule, not a source rule: the generator strips the
line-start marker (the only position `~` occupies in `.kz`) when embedding
source, and the corpus sources' whole-line comment prose was swept (343
files, comment-only, zero code lines — the diff was checked). A reference
corpus teaches the PURE surface, because pure Koru is the surface that
rejects the tilde. Residual `~` in artifacts is legitimate: error pins
quoting the rejected form, and skill prose explaining the rule itself.

The topology is this fragment's own fourth door: a subsystem (the generator)
borrowing another's machinery (the raw test files) and bringing different
assumptions with it. The generator answered "present the source as-is"; the
doctrine demanded "present the pure surface". Nothing executed the output, so
nothing complained — the doctrine's own line: *an unguarded path is not the
neutral absence of a guard; it runs whatever its borrowed machinery believes.*

## The blog door (2026-08-16)

The published blog was the by-example door's twin, unmeasured. Measured before
the sweep: 1,857 tilde-lines across 139 posts — `~tor`, `~import`, `~hello()`
in the top context-facing artifact the language writes for humans, teaching
the negation of the rule for a year, green because nothing executes prose.
Half the lines sat inside ```` ```koru ```` fences; a further 30 were Koru
constructs rendered as unfenced prose. Stripped in one sweep: the line-start
marker (the only position it occupies), matching the by-example generator's
mechanism. Kept: strings (`~/notes.txt`), markdown strikethrough, benchmark
data (`~1.25 ns/iter`), other-language fences — the doctrine's axis is code
position vs data, and this sweep kept it.

Two things were new here and are worth carrying:

- **The enforcement is the facet.** A pure-Koru `.k` file Rejects the tilde —
  PARSE003, at the parser, with a teaching message. The strongest wall a
  presentation context can have is to live in a file the lexer itself policed.
  The registry tests (`430_057`/`430_058`) moved from `.kz` to `input.k` —
  the harness runs both — so the corpus's pure surface is now compiler-held,
  not convention-held. Any future regression to `~` in a pure test is a parse
  error, discovered in the same commit that writes it.
- **The post-door needed its own guard-shaped wall, not a one-time sweep.**
  Unlike corpus files, posts have no lexer — they are prose. A check
  (`korulang_org/scripts/check-post-tildes.mjs`, run by `bun run blog:index`)
  walks every post with the corrected fence parser and fails on a tilde in
  code position: inside ```koru fences always; in prose only when the next
  character is a letter/`*`/`[`/`(` (the Koru-construct shapes), so benchmark
  data and markdown survive. The guard is at the generation door, like the
  by-example generator's — the third door in this fragment's log, and the
  first one enforced by failing the toolchain rather than by editing output.

Related: [[frag-k-file-is-a-full-program]] (the `.k` half of the same rule),
[[frag-a-watcher-off-the-normal-path-is-not-a-wall]] (the general shape).
