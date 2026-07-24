---
type: belief
id: frag-tilde-marks-the-host-boundary
provenance: ruled while orienting on the budgeted interpreter / resource bridge / shell direction; settles the design question 430_047's TODO had carried open since 2026-05-15
ts: 2026-07-24
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

This settles a question that had been open since 2026-05-15, when triage of
`430_047` found `std/runtime:run` accepting a bare `"ping()"` and asked whether
interpreter source was implicit-Koru or required the tilde. It is implicit. The
lenient acceptance was right; the pin asserting otherwise was wrong, and has
been inverted to guard the rejection instead.

The motivation is not tidiness. A corpus that shows `~`-prefixed interpreter
source teaches every future reader — human or agent — a form the language does
not want, and each such example is load-bearing precisely because nobody
verifies prose and test fixtures against a rule no tool enforces. That is the
poison; the sweep is the antidote.

The wall is built: `findHostTilde` in `koru_std/interpreter.kz`, called from
`run` and `run-cached` — the single choke point, since `std/runtime:run`
delegates there. It returns the declared `parse-error` branch with real
line/column and a message naming the reason rather than a bare parse failure,
because a user arriving from `.kz` reaches for the tilde by habit and deserves
to be told why it is wrong here.

**The scan skips string literals, and that is not a concession.** `~` inside a
string is data — `open(path: "~/notes.txt")` is the most common path on a unix
machine, and a rule that made it unexpressable would be wrong, not strict. The
axis is code position vs. data, never "contains the character." `430_054` pins
the path case; `430_047` pins the rejection.

Open: **both pins are inert on the board.** They live in `430_RUNTIME`, whose
category-level `TODO` unconditionally marks every test beneath it — the harness
has no per-test override, so parking a cluster silently disarms walls inside it,
including walls for rules that are ruled and shipped. Verified by hand instead
(`~ping()` → PARSE ERROR; `"~/notes.txt"` → OK). Arming them wants a harness
ruling, not a test relocation: relocating would be the route-around.

Related: [[frag-k-file-is-a-full-program]] (the `.k` half of the same rule).
