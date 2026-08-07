# 610_007 — the dangling slice: analysis and position

Second-opinion ruling analysis, requested 2026-08-07. Written by an agent on a
different model family from the sessions that measured the facts below; every
fact was re-reproduced independently before reasoning. Probes lived in
`/tmp/610probe/`; compiler `zig-out/bin/koruc` against the working-tree
`koru_std`.

## The four facts, re-verified

All four reproduce. (One reproduction attempt initially failed because two
`koruc` invocations were run concurrently in the same directory — koruc uses
fixed intermediate filenames (`backend.zig`, `output_emitted.zig`, `a.out`) in
cwd, so parallel compiles in one directory race and can report each other's
verdicts. Run serially, all four facts hold. Worth knowing for anyone probing
by hand.)

1. **The hazard is real and cheap.** `from-page → take → read → free → print`
   compiles clean, prints `after free: [�U��J��rld]`, exits 0. Four ordinary
   steps, no `proc` escape hatch.
2. **`take` poisons its input.** Using `v` after `take(s: v)` →
   `error[KORU030]: Use-after-discharge: binding 'v' was already discharged`.
3. **`free` poisons its input.** Using `owned` after `free(s: owned)` — same
   KORU030, and my extra probes show it is robust: it fires for consume-uses
   (double free), borrow-uses (`read`, `len` after free), on branch-payload
   bindings and on rebound mid-flow bindings alike.
4. **The use site is not the hole.** `print.ln("{{ t:s }}")` and
   `print.ln(text: t)` behave identically — both compile, both print garbage.
   `t` was never tainted, so there is nothing at the use site to check.

## A fifth fact, measured here, that changes the question

**No `free` is needed to dangle the slice.** This probe has the owner alive
the whole time:

```koru
| ok v |> take(s: v): owned |> read(s: owned): t
       |> append(s: owned, text: "…256 bytes…")
       | ok |> print.ln("no free, owner alive: [{{ t:s }}]")
```

Compiles clean, prints `no free, owner alive: [ļ���vrld]`, exit 0.

The reason is structural: a `String`'s `data` slice IS its allocation record
(string.kz:265), so **every mutator invalidates outstanding slices** —
`append` reallocs (string.kz:240), `append-char` reallocs (:257), `pop-char`
reallocs (:292), `clear` frees (:298). `free` is only one member of a
five-member invalidation family.

This is the single most load-bearing measurement in this document, because it
falsifies the narrow question as posed. A phantom that propagates *liveness* —
"`t` dies when `s` is discharged" — closes exactly one of the five
invalidators and leaves the other four compiling clean, with the owner alive
and the poison pass rightly silent. To be sound, the annotation must mean
"`t` dies when `s` is discharged **or mutated**", which is aliasing-XOR-
mutability. That is not a phantom; that is a borrow checker.

## Reachability in the real corpora

28 live call sites of `std/string:read` outside the compiler's own sources:

- **koru-libs/examples** (4): `component_dock_stack_live.k:48`,
  `component_stack_live.k:35`, `component_text_input.k:47`,
  `component_textarea.k:59`.
- **koru-examples** (24): `chal-db-shelf/bridge.kz:14`,
  `chal-tui-gitgazer/b_git_store.kz:53`, `c_gitgazer.kz:69`,
  `gallery/gallery.k:239,252`, `kopium-headless/headed.k:191,252,304,305,310`,
  `kopium-headless/live.k:94,125`, `kopium-headless/probe_store.k:14`,
  `kopium/c_chat_pane.k:140`, `kopium/d_turns.k:197,198,203`,
  `kopium/holes/3/workaround.k:30`, `todo/d_turns.k:190,191,196`,
  `todo/todo_store.k:20,21,36`, `todo/todo_tui.k:59,63`,
  `todo/todo_tui_my_copy.k:27`.

Classification, having read each site:

- **~24 of 28 consume the slice immediately, in the same flow step, from a
  store-held owner.** The shape is always
  `query … ! query X |> read(s: X): t |> <one consumer>("{{ t:s }}")`. The
  borrow never crosses a handler boundary. These sites are de-facto *scoped*
  borrows — they use `read` as if it were borrow-for-the-call, because that is
  the only shape a human can verify by eye.
- **4 sites let the slice travel**, and each is safe only by inspection:
  - `kopium/d_turns.k:203-207`: `read(s: d): utext` →
    `chat-body(prompt: utext)` → … → `clear(s: d)` → `send(body)`. Safe
    because `chat-body` copies (`kopium/auth.kz:48-64` escapes into a fresh
    buffer, `toOwnedSlice`). If `chat-body` ever returns a view — the exact
    refactor that exposed hole 3 — `clear` at :207 frees the bytes `send` is
    about to read.
  - `kopium-headless/headed.k:191` and `live.k:125`: `read → wire:clean(raw)`
    where `clean` is `{ raw: string } -> string` returning a **sub-slice of
    its input** (wire.kz:66-69); the result then travels through
    `remember-said` / `record` / `bridge:run`. Safe because the owner is
    store-held and nothing mutates it mid-flow — verified only by reading
    every downstream tor.
  - `kopium/holes/3/workaround.k:30`: `read → print → free` — correct order,
    maintained by hand, one transposition from fact 1.
- **Sites where an owner dies before its borrow today: zero in live code.**
  But the shape has shipped a real bug once already: kopium increment C's
  blank chat pane (holes/3, found 2026-08-01) is this exact hazard through
  `koru/yyjson:as.string` — an arena borrow escaping the tor that owned the
  doc, via an ordinary point-free refactor no reviewer would flag. Silent
  NUL bytes, exit 0, not a crash.

Inventory of view-returning tors: `std/string:read` (string.kz:100-101,
`~read -> s.data`) is the **only** stdlib tor returning a raw borrow of a
parameter's buffer. `io:read.ln` dupes (io.kz:89). `substring` and the whole
query/transform family allocate (string.kz:106-113, 173-175). Outside the
stdlib: `koru/yyjson:as.string` (arena borrow) and app-level sub-slicers like
`wire:clean`.

So: the hazard is one contrived test plus one real shipped bug plus four
inspection-only sites — **and 28 sites of latent exposure that grows with
every app**, because nothing checks the ordering discipline all 28 currently
follow voluntarily.

## The decisive contrast the existing checker already gives us

Two of my probes differ by one token and split exactly along the seam:

- `free(s: owned) |> len(s: owned)` — consumer takes the **handle** →
  **KORU030, caught.**
- `free(s: owned) |> print.ln(text: t)` where `t = read(s: owned)` earlier —
  consumer takes the **derived slice** → compiles, garbage.

Everything routed through a *binding* is already policed, at every site and
shape measured today (facts 2, 3, and my f3b–f3e variants; 335_052 covers the
record-field and interpolation shapes). The only values that escape the poison
pass are those that stop being bindings of the owner — raw projections of its
memory. The checker is not underpowered; the stdlib seam manufactures values
the checker was never supposed to have to track.

## Position

**Lars's hypothesis is right, and it can be stated more precisely than he
stated it: the surface is wrong on the *return* axis only.** Koru already has
a sound borrow: the parameter borrow. A bare `<state>` param borrows for the
call and does not consume (ruled 2026-08-06); the callee cannot outlive the
call; the binding at the call site stays checked by KORU030. What Koru lacks —
and what I recommend it **continue to lack, on purpose** — is the returned
borrow. The rule that resolves 610_007:

> **Borrows flow down, never up.** A slice of someone else's buffer may enter
> a call as an argument; it may never leave a tor as a return or terminal
> payload. A terminal payload owns what it carries — which is the already-
> ratified borrow model of 2026-06-11, now enforced instead of waived for
> `read`.

`~read -> s.data` (string.kz:101) is not a missing annotation; it is a
violation of the ratified model that has been grandfathered in. The NEEDS_
RULING asks "how is a borrow spelled?" — the answer is that a *returned*
borrow is not spelled, because permitting it is what creates the demand for
lifetime machinery, and fact 5 shows that machinery has to be a full aliasing
discipline, not a liveness tag, to actually be sound.

### What replaces `read`

1. **Hot path, zero-copy: consumers borrow the handle.** The print/format/
   vaxis family accepts `*String<view|instance>` directly, and interpolation
   gets a handle form — spelled today as it would appear on the survivors:

   ```koru
   ~pub tor write-at { x: u16, y: u16, s: *String<view|instance> }   // borrow-for-the-call
   print.ln("{{ label:S }}")                                          // reads label.data inside the emitted step
   ```

   The read happens *inside* the call/step, where the owner binding is live
   and KORU030-checked (measured: the handle route already errors after
   free). ~24 of 28 corpus sites collapse from
   `read(s: X): t |> consume("{{ t:s }}")` to `consume("{{ X:S }}")` — one
   step shorter, zero copies, zero allocations, and safe by construction.
   The per-frame TUI draw paths (todo_tui, gitgazer) keep their zero-copy
   property fully.

2. **Escape path, explicit copy: the substring precedent.**

   ```koru
   ~pub tor snapshot { s: *String<view|instance> }
   | ok *String<view!>
   | err string
   ```

   Allocates like `substring` (string.kz:173-175) and returns an
   obligation-carrying handle, so the copy cannot leak — unlike a hypothetical
   "read that allocates", whose primitive-`string` return carries no
   obligation and leaks by design. This is why the NEEDS_RULING's third
   option ("make `read` allocate") is almost right but not quite: the
   allocation must come back as a *handle*, or the fix trades a dangle for a
   leak. Hole 3's measured workaround already proved this shape works and
   what it costs: one memcpy per genuine escape, at turn boundaries (Enter
   key, network reply), never on a frame path. 4 of 28 sites pay it.

3. **`koru/yyjson:as.string` copies out of the arena** (or returns a
   `*String<view!>`), closing hole 3 by the same law.

4. **Enforcement.** For subflow-visible returns the checker can see the
   violation: a terminal payload or `->` return that projects a pointer
   parameter's memory (`-> s.data`) is a compile error — a new KORU0xx in the
   semantic pass alongside KORU030. For opaque `~proc |zig` bodies it cannot
   be checked (Koru is emit-only; proc bodies are opaque strings), so there
   it is a stdlib law plus review — exactly the status the rest of the proc
   escape hatch already has. 610_007's `EXPECT CONTAINS borrow` pin can then
   go green against the real diagnostic.

### Cost, honestly weighed against the systems-speed thesis

- The dominant pattern gets **faster or equal**: parameter borrows are the
  same zero-copy slice access `read` gives today, minus one flow step.
- Genuine escapes pay one allocation + memcpy each. In the entire measured
  corpus that is ~4 sites, all on human-interaction or network boundaries
  where a memcpy of a chat line is noise.
- The real cost is **surface work**: the print/fmt/vaxis family needs handle
  overloads (or one interpolation extension `{{ h:S }}`), and 28 call sites
  need a mechanical one-step rewrite. Wide, shallow, and each rewritten site
  gets shorter.

### Second-best option, and why I reject it

The return-lifetime phantom — spelled, so it is rejected concretely rather
than abstractly:

```koru
~pub tor read { s: *String<view|instance> } -> string<~s>   // "return borrows s"
```

Rejected on three measured grounds:

1. **Unsound as specced.** Fact 5: tying `t`'s life to `s`'s *liveness*
   misses all four mutating invalidators. Sound means "discharge OR mutation
   ends the borrow", i.e. while `t` lives, `s` is frozen — shared/exclusive
   borrow tracking. That is a borrow checker delivered in installments, each
   installment discovered as a CVE-shaped hole like this one.
2. **It infects the primitive type.** `wire:clean` is `string -> string` and
   returns a sub-slice of its input (wire.kz:66-69). An annotation on the
   `*String` seam doesn't reach it; to be sound, `<~x>` must propagate
   through every `string`-valued tor, interpolation, record field, and store
   column — the base string type becomes lifetime-parameterized everywhere.
3. **It multiplies the 335_052 matrix.** That fix's own lesson is that
   coverage is the cross product of sites × shapes. Poisoning polices
   bindings at all sites today. Lifetimes add a third axis (every value
   carries an owner identity) — the checker surface grows multiplicatively,
   in a checker that lives in `koru_std/compiler.kz` and is already the
   self-hosting pressure point.

The "read-scope construct" option from the NEEDS_RULING is, on inspection,
what parameter borrows already are — a borrow bounded by a call — so it is
subsumed by this position rather than rejected: the scope construct exists,
ruled 2026-08-06; it just needs consumers willing to use it.

### What would change my mind

A profiled workload where all three hold at once: (a) view production is on a
hot path (a streaming parser emitting thousands of sub-token views per
second, not a per-turn chat line); (b) the consumer genuinely cannot take the
handle (crosses a boundary the borrow-for-the-call cannot span — stored,
returned upward, or FFI); and (c) the copy is visible in the profile. No
current corpus code satisfies even (a). If that workload lands, the
"borrow-obligation surface" string.kz:112 promises is earned — and it should
be designed as a real region/borrow system priced up front (mutation freezing
included, per fact 5), not as a phantom retrofit. Until then, "cheap views
wait" stays true, and may stay true indefinitely.

Separately, a smaller thing would partially change my mind: if extending
interpolation/print to accept handles turns out to be deep rather than
shallow (e.g. interpolation cannot reach a pointer field), the copy-only
variant — retire `read`, add `snapshot`, accept the memcpy at all 28 sites —
is still better than lifetimes, at a cost the corpus measures as negligible.

## Verdict

- Fact 1–4 all reproduce; fact 3's one failed reproduction was my own probe
  race (two koruc runs sharing a directory), not the compiler.
- New measurement: the slice dangles **without any free** — `append` after
  `read` garbles the borrow with the owner alive. Liveness propagation is
  therefore unsound as a fix, not merely expensive.
- Lars is right: needing lifetime machinery here means the surface is wrong.
  Precisely: the *returned* borrow is the one borrow Koru cannot police with
  existing machinery, and it should be banned, not annotated.
- Cure: enforce the 2026-06-11 rule — terminal payloads own what they carry.
  Retire `read`; consumers borrow the handle (zero-copy, already
  KORU030-protected, ruled 2026-08-06); explicit `snapshot` copy for the ~4
  genuine escape sites; yyjson copies out of the arena.
- Second-best (return-lifetime phantom `-> string<~s>`) rejected: unsound
  without mutation-freezing, infects primitive `string` transitively, and
  multiplies the site×shape checker matrix.
