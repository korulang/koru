---
type: belief
id: frag-tilde-marks-the-host-boundary
provenance: ruled while orienting on the budgeted interpreter / resource bridge / shell direction; settles the design question 430_047's TODO had carried open since 2026-05-15. Corrected 2026-08-07 after Lars asked whether the interpreter still accepted `~` and the answer turned out to be "on one route it is mandatory"
ts: 2026-08-07
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

Related: [[frag-k-file-is-a-full-program]] (the `.k` half of the same rule),
[[frag-a-watcher-off-the-normal-path-is-not-a-wall]] (the general shape).
