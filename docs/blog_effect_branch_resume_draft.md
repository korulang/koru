# Effects that resume you

*Draft — register: blog post. Every code block below is verbatim from a regression
test, cited by ID. Every test cited in the body was run green as of 2026-07-01
(multi-arm resume landed that session); the one red is quarantined in "Where it
stops" so no claim in the body outruns its evidence.*

---

Most languages give you two ways for a function to hand control back to you. It
can **return** — done, here's a value, goodbye. Or it can **call you** — a
callback, a visitor, an iterator's `next`. Return is one-shot and it's over.
Callbacks invert your control flow until you can't find the thread.

Koru has a third thing. An event can **yield** mid-flight — stop, surface a value
to its caller, and *wait to be resumed with a typed reply* — and then keep going.
The handler isn't a callback bolted onto the side. It's a branch, written inline
in the flow, and the value it sends back is type-checked against what the event
asked for.

If you've met algebraic effects, you know the shape. What's different here is that
the resume value is **a first-class part of the event's type**, the glyph that
produces it is **fixed by the declaration**, and using the wrong glyph is **a
compile error** — not a footgun you find at runtime.

## The shape

You declare an effect arm with `!`, give it a payload type, and an arrow for the
resume type:

```koru
~pub event prompt-user { question: []const u8 }
! ask []const u8 -> []const u8
| done
```
<sub>— `210_074_effect_branch_resume_type`</sub>

Read it as: `prompt-user` fires; somewhere inside it `! ask`s a `[]const u8` (the
question) and expects to be **resumed with** a `[]const u8` (the answer). `| done`
is the ordinary continuation branch — where the flow goes once the effect is
discharged.

Now the call site. You fire the event, and you handle the `! ask` arm by
**producing** the resume value with `->`:

```koru
~prompt-user(question: "What's your name?")
! ask _ -> "Alice"
| done r |> std/io:print.blk {
    reply was: {{ r:s }}
}
```
<sub>— `400_082_effect_branch_resume_value` → prints `reply was: Alice`</sub>

`! ask _ -> "Alice"` means: when the flow yields at `ask`, resume it with
`"Alice"`. Control goes *back into* `prompt-user`, the proc gets `"Alice"` as the
answer, runs to its terminal `| done`, and the flow continues at `| done r`, which
now binds the result. The handler is three tokens — `! ask _ -> "Alice"` — and it
reads top-to-bottom in the same flow as everything else.

## The resume value is a real value

It isn't limited to literals. Whatever you can write as a Zig expression at body
position, you can resume with. Bind the payload and echo it:

```koru
~transform(payload: 7)
! squarify n -> n
| done result |> std/io:print.blk {
    result is {{ result:d }}
}
```
<sub>— `400_083_effect_branch_resume_binding`</sub>

Compute with it:

```koru
~request(payload: 21)
! double n -> n * 2
| done r |> std/io:print.blk {
    result is {{ r:d }}
}
```
<sub>— `400_085_effect_branch_resume_arithmetic` → `42`</sub>

Or — the hot path — produce the resume value by **calling another event**, with no
intermediate binding. `->`'s right-hand side can be an invocation, so a
single-payload event's output threads straight through as the resume:

```koru
~pub event mix { x: i32 } -> i32
~proc mix|zig { return x + 1; }

~pub event driver {}
! step i32 -> i32
| done i32

~driver()
! step p -> mix(x: p)
| done r |> std/io:print.ln("{{ r:d }}")
```
<sub>— `400_117_effect_resume_produce_is_call` → `42`</sub>

This is "produce *is* the call": `! step p -> mix(x: p)` resumes `driver` with
whatever `mix` returns. The emitter binds the call to a temp and feeds it back as
the resume value. No tagged union, no boxing — `mix` is a bare-return `-> i32`
event, so this is a plain integer threaded through a function call on the hot path.

## Effects as iteration

Once an event can fire an arm more than once, "yield a value, resume, repeat" is
just a loop. Here's the entire shape of a `for` over a slice, with no compile-time
macro machinery — only effect branches and a Zig `for` in the proc body:

```koru
~pub event each-i32 { items: []const i32 }
! item i32

~proc each-i32|zig {
    for (items) |it| item(it);
}

~each-i32(items: &[_]i32{ 10, 20, 30 })
! item v |> std/io:print.blk {
    saw {{ v:d }}
}
```
<sub>— `400_086_effect_branch_iter_slice` → `saw 10 / saw 20 / saw 30`</sub>

`! item` fires once per element; `| std/io:print.blk { ... }` is the loop body. The
`each` arm here has no resume type — it yields and the body chains with `|>`. The
suggestion writes itself: stdlib `for` is *already* an effect-branch event wearing
a nicer coat.

## The discipline is the feature

Here's the part that makes this a language feature instead of a clever trick.
**Three glyphs, three jobs, and the declaration decides which one is legal:**

- `->` **produces** a resume value (the effect declared `-> T`, no branches).
- `=>` **constructs** a branch (the effect has named arms to select).
- `|>` **chains** a step (it cannot introduce a value of its own).

An effect declared `-> T` has a single anonymous resume value and *no* branches —
so constructing a branch with `=>` is meaningless, and Koru rejects it:

```koru
~query(q: "x")
! ask _ => 42        // KORU102: `=>` constructs a branch; this effect has none
| done r |> std/io:print.ln("{{ r:d }}")
```
<sub>— `400_122_reject_construct_glyph_on_resume_effect` (MUST_FAIL, asserts `KORU102` and `use `->` to produce it`)</sub>

Without that rule, `=> 42` would silently emit `return 42` and *look* like it
worked. That's the whole ballgame for a performance language: an ambiguous glyph is
a silent miscompile, so the compiler refuses it at the boundary instead of guessing.

The same boundary catches the dual mistakes. Resume with the wrong type —

```
510_102_resume_type_mismatch       → rejected (backend compile error)
```

— or try to *discard* a resume value the arm is obligated to produce —

```koru
~prompt-user(question: "?")
! ask _ |> _          // the arm declares `-> []const u8`; `_` produces nothing
| done _ |> _
```
<sub>— `510_103_resume_body_discard` (MUST_FAIL) → rejected</sub>

Both are compile errors. The resume value is part of the contract; you cannot
quietly drop it.

## Linear obligations ride the resume

Here's where this stops being "nice resumable handlers" and becomes the thing
worth bragging about. The resume arrow doesn't just carry a *type* — it carries a
*phantom state*, and that state is governed by the same linear-obligation discipline
as everything else in Koru. The compiler reasons about how many times an arm fires,
and refuses any program where an obligation could leak across a firing boundary.

A `! each` generator fires once per element and carries no resume state. So an
obligation *born* inside the handler must die inside the same firing — create it,
discharge it, balanced:

```koru
~gen(n: 3)
! each i |> create(id: i): r |> destroy(r)
| done _ |> _
```
<sub>— `400_100_effect_obligation_discharged_in_firing` → `freeing 0 / freeing 1 / freeing 2`. `create` issues a `*Resource<active!>`; `destroy` discharges it; balanced per firing.</sub>

Drop the `destroy` — only *use* the resource — and the obligation has no way out of
the firing. Rejected:

```koru
~gen(n: 3)
! each i |> create(id: i): r |> use(r)   // active! created, never discharged
| done _ |> _
```
<sub>— `400_103_effect_obligation_cannot_escape` (MUST_FAIL) → `KORU030: ... was not discharged`. This is the discriminator: if obligation tracking *weren't* wired through `! each`, this would silently compile.</sub>

And the rule that proves the design is symmetric rather than ad hoc: a resume type
may **discharge** an obligation (`-> *R<!active>` — cleaned up in scope, handed
back; that's `400_106`, green) but may **not issue** one. Because a `!` arm fires
0-to-N times, a resume that issued a fresh obligation per firing would hand back
something un-discharged every time — incoherent — so it's rejected at the
*signature* level, without inspecting a single line of the body:

```koru
~pub event borrow { n: usize }
! lend usize -> *Resource<active!>     // resume issues an obligation — forbidden
| done usize
```
<sub>— `400_107_effect_resume_cannot_issue_obligation` (MUST_FAIL) → `KORU027: ... cannot issue an obligation`.</sub>

That's the claim in one line: **resumable effects that respect linear types.** You
get algebraic-effects-style control flow, and the borrow checker rides along on the
resume edge.

## Multi-arm resume — "effects having effects → sessions"

An effect's output isn't limited to one anonymous `-> T`. It generalizes to a
flat sum of named arms, and the handler resumes by **selecting** one with `=>`:

```koru
~pub event request { payload: i32 }
! ask i32
    | halved i32
    | timeout
| done i32
...
~request(payload: 20)
! ask n => halved @divTrunc(n, 2)
| done r |> std/io:print.ln("{{ r:d }}")
```
<sub>— `400_114_effect_multi_arm_output` → prints `10`. The `=>` here is
*correct*: this effect **has** arms, so you construct one — the same glyph
discipline as everywhere else, and `->` on an arms-effect is rejected
(`400_125`, KORU102), as is an unknown arm name (`400_126`, KORU021).</sub>

The proc consumes the sum the same way it binds a scalar today: `const r =
ask(payload)` binds a synthesized `union(enum) { halved: i32, timeout: void }`
and dispatches with an ordinary Zig `switch`. Both decl spellings — arms
indented one level under the `!`, or riding its line — collapse to the same
AST (`210_092`/`210_093`, machine-checked byte-identical).

And the obligation discipline rides per arm, with the same directionality as
the single resume: an arm may **discharge** (`| granted *R<!active>`,
`400_127`) but never **issue** (`400_124`, KORU027) — a `!` arm fires 0-to-N
times, so issuing per firing would leak by construction.

## Where it stops — the honest frontier

Everything above runs green today. One pinned test describes where the arc is
deliberately stopped — it's the *next phase*, not a bug. It's marked
`MUST_RUN` and currently fails: an aspirational pin capturing intent ahead of
implementation.

**Effect events implemented by a subflow, not a proc.** Right now every
effect-bearing event is `~proc`-backed — the proc is the trust boundary, host code
fires the effect and we trust it "unsafe"-style. The open surface is an
effect-bearing event implemented by a **Koru subflow**, so the effect firing and
its obligations are checked at the *flow* level instead of trusted to opaque host
code. That flow-level checking of effects is the genuinely new ground this whole
arc opens.

```koru
~gen => for(0..n) ! each i | done n
```
<sub>— `400_115_effect_event_via_subflow` (PROPOSED — currently red; the subflow-fires-an-effect spelling is intent, not established grammar).</sub>

Also still open on the multi-arm side: arms with *record* payloads
(`| halved { x: i32, y: i32 }`), and the phantom checker honoring an arm's
discharge at the flow level (the emit is correct — `400_127` — the semantic
accounting is the remaining depth).

## The receipts

Verified green this session (2026-06-27):

| Test | What it proves |
|------|----------------|
| `210_074`, `210_079`, `210_080` | parser accepts the `-> T` resume declaration + body-position producers |
| `400_082`–`400_086` | resume values: literal, binding, numeric, arithmetic, slice-iteration |
| `400_106` | emits correct Zig for the resume out-edge |
| `400_111` | multi-kind effect, cross-target |
| `400_116`, `400_117` | the `->` producer glyph; produce-is-the-call |
| `400_122` | `=>` on a `-> T` effect is rejected (KORU102) |
| `510_102`, `510_103` | resume type mismatch and resume-value discard are rejected |
| `400_100`, `400_105` | an obligation born in a handler is discharged in-firing |
| `400_103`, `400_104`, `400_107` | obligations cannot escape a firing; a resume cannot issue one |
| `400_108` | auto-discharge splices disposal into an effect-branch handler |
| `210_092`, `210_093` | multi-arm decl grammar, both spellings, byte-identical AST |
| `400_114` | multi-arm resume runs end-to-end (`=>` selects, proc switches the union) |
| `400_125`, `400_126` | `->` on an arms-effect and unknown arm names are rejected |
| `400_124`, `400_127` | per-arm obligations: issue rejected at the signature, discharge emits clean Zig |

Frontier (red, pinned as intent): `400_115` (subflow-implemented effects).

The tests are the spec. If this post and the compiler ever disagree, the compiler
wins and this post is the bug.

<!--
CITATIONS — machine-checked by scripts/check_blog_citations.mjs against the latest
snapshot. Every NNN_NNN id appearing in the prose above MUST be classified here,
and the snapshot status must match: `green` ⇒ success, `frontier` ⇒ not success.
green: 210_074 210_079 210_080 210_092 210_093 400_082 400_083 400_084 400_085 400_086 400_100 400_103 400_104 400_105 400_106 400_107 400_108 400_111 400_114 400_116 400_117 400_122 400_124 400_125 400_126 400_127 510_102 510_103
frontier: 400_115
-->

