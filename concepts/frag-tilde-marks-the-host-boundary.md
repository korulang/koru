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

Open: **the wall is not built.** The current interpreter accepts both forms via
`src/flow_parser.zig`, so the tilde is presently ignored rather than rejected.
`430_047` is the red pin holding that gap, and the interpreter rewrite owns it.
The rewrite should reject the tilde with a diagnostic that names the reason —
"`~` marks host-embedded Koru; interpreter source is already pure Koru" — rather
than a bare parse failure, since a user arriving from `.kz` will reach for it
by habit.

Related: [[frag-k-file-is-a-full-program]] (the `.k` half of the same rule).
