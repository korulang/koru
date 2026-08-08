---
type: belief
id: frag-a-representation-rule-must-not-eat-a-name
provenance: PARSE003 refused a lone payload-carrying terminal branch — "a one-variant tag union" — and the only way out deleted the branch's NAME. Orisha's `| response { status, body, content-type }` became an anonymous record on 2026-08-03 and every doc line, example and router arm kept using the dead spelling. Ruled by Lars 2026-08-08; implemented, pinned as 210_190
ts: 2026-08-08
---

# A rule about representation must not eat a name

"One variant is a wasteful tag union" is a true statement about *machine
representation*: a tag plus double data movement for a value with exactly one
shape. The rule that follows from it — lower a single outcome to a plain return —
is right. What it must not do is take the author's **label** with it, and
Koru's did, because refusing the declaration was the only way it knew to say so.

The cost lands entirely on libraries. A program with one outcome shrugs; a
framework *is* its nouns. `response`, `redirect`, `not-found` — that vocabulary
is the public face, and this rule forbade precisely the case a framework needs
most: one outcome, strongly named. Orisha lost `response` in a migration that
was correct line by line, and the name went on living in every doc comment,
every example, and the router's own generated code, none of which the compiler
could have parsed. **The docs were not stale; the language had removed a word
they depended on.**

The general shape: **a constraint on how something is REPRESENTED and a
constraint on how it may be SPOKEN are different constraints, and a rule that
enforces the first by removing surface has silently made the second.** The
question to ask of any such rule is: what could the author previously say that
they now cannot, and is that loss part of the point? Here it never was — nobody
decided a single outcome should be anonymous, it fell out of how the objection
was enforced.

The fix keeps both halves honest: a 2+-field payload lowers to a bare return of
that record (no tag, no union, no runtime cost) and the branch survives *only* so
its name is a constructor for it. A one-field payload is still refused, because
`-> T` genuinely is the whole value there and `response 200` is not a vocabulary
anyone wants.

**The blast radius was the lesson in implementation.** Five separate emitters
write a branch constructor — the event-aware one, the type-registry one, the
context-driven one, and two more inside the visitor — and each had to be taught
that this name means *no wrapper*. Four of the five looked like the right one
before instrumenting proved otherwise. See
[[frag-a-name-mangling-dispatcher-assumes-a-parity-nobody-maintains]]: when N
copies answer one question, teaching one of them is indistinguishable from
teaching none.
