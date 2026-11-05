# package-assay: vaxis — the reactive TUI wrapper

Target: `koru-libs/vaxis` (`index.kz`, 4,690 lines) — a reactive TUI
library over libvaxis (fetched as a Zig package dep), stated purpose
"wrapping libvaxis with phantom type obligations": `run` owns the
terminal as one effect-branch event (`! draw`, `! char`, `! tick`,
`! key-raw`, `! mouse-raw`, named keys/mouse), ~30 painted widgets,
and a markup layer (`<dock>`, `<stack-panel>`, `<text>`, component
tags) driven by four `[comptime|transform]` tors in-file. Assayed
against koru `main @ 55ad1a0f7` (worktree `assay-vaxis`) and koru-libs
`0fcacb9` + uncommitted WIP (`vaxis/tests/frontier/build.zig` — a stale
emitted artifact only; `tests/frontier/*.md` wall files are the survey
gold: recorded toolchain walls with verdicts).

## exists (named surface + evidence)

- **Effect-branch `run`** — `!` arms for draw/input/tick/raw taps with
  `| done`/`| err`, one long-running proc owning the terminal
  (`index.kz:376`+). Presence-gated `tick_ms` heartbeat
  (`! ?tick i64` — the `?`-optional effect arm) refires draw.
- **Deep transform machinery** — four `[comptime|transform]` tors
  (`run` `claims_descendants`, `view`, `shader`, `component`, plus
  `[keyword|comptime|transform|pre] default`): the compiler already
  hands the package ordering controls (`pre`, `claims_descendants`),
  block-source (`Source`), invocation/item/program walks, and
  `SiteResult` rehoming — the frontier walls were closed mostly
  *inside* these hooks (arm-capture fix 9c9a464, markup routing fixes).
- **Pump `! wait` fd-interest contract** — `wait(i) -> { fd, wait_ns }`
  (`index.kz:366`) implements the readiness vocabulary a pump
  participant needs (`koru_std/pump.wait.kz`); the TUI loop can park
  on the tty fd + tick timer with one shape.
- **External Zig deps** — `std/deps:requires.zig` (libvaxis pinned by
  git+hash), `std/compiler:requires` + `std/build:requires` wiring the
  dep into backend and output builds — a package can pull a host-lang
  library and expose it behind Koru tors.
- **Module reach-back** — `$mod.` in spliced proc bodies is the
  sanctioned spelling (pin 400_155) for a transform-spliced proc to
  reach its own module's state.
- **Styled/segment-accurate paint** — `Style` incl. packed-RGB fg/bg
  (progress Wall 1 FIXED), `write-at`/`write-styled`/`write-in` via
  `printSegment` (grapheme-width-correct, Wall 2 FIXED).
- **Markup/widgets** — `component`/`view` transforms, `wa_qual` builtin
  tag resolution (`<progress-bar …/>` → tor), ~30 widget tors
  (glance: `progress-bar`, `spinner`, `pulse`, `timer`, `stopwatch`,
  `text-input`, `list`, `viewport`, `wrap-lines`, `scrollview`,
  `paginator`, `help`, `table`, `filepicker`, `textarea`).

## missing-blocker (probed or cited absence)

- **Wildcard-payload arm bindings can't be typed in the capture
  machinery.** Cited at artifact level: `tests/frontier/
  run_transform_walls.md` — `! each *` (wildcard payload) under a
  nested `std/store:query` has no decl-side payload type for
  `lookupBranch` to find, so the binding can't capture ("element-type
  inference… different mechanism needed", still-open per the doc).
  Today it blocks `! each *`-under-query programs; a Koru TUI handler
  iterating a store inside an event arm hits it on the wildcard
  spelling. **The one commission-worthy compiler item.**
- **`i64 /` emits uncompilable-by-Zig-rules integer division.** Cited:
  `tests/frontier/charm_spinner_walls.md` — "Surface `i64 /` still
  emits Zig `/` (needs `@divTrunc`) — FPS math stays in the zig
  builtin (honest float, not a library dodge of a koru expression)."
  The package's own record of being pushed into Zig for arithmetic the
  language spells — the koru-libs doctrine's canonical gap shape. Not
  re-probed this session (my `1000 / frame_ms` subflow spelling failed
  to parse, `unknown tor 'div:…'` — a separate, unmeasured spelling
  question; the emission claim stands on the cited wall, not on me).
- **Unknown-field acceptance hole (pin 800_003).** Cited: progress
  walls — unknown fields on painted elements reach Stage D rather than
  being refused early ("separate analysis hole"). A pinned defect, not
  a vaxis-specific need.

## missing-but-portable (absent, workaround shape obvious)

- **`<text>` inside `<stack-panel>` nested in a `<dock>` slot** — the
  walls doc's one open routing case (deeper nesting still classifies
  text as a component call → KORU040). Package transform work.
- **Spring/harmonica animated transitions** — Charm parity item; the
  `! tick` substrate now exists, the easing is widget math. Package work.
- **`$mod.` boilerplate** — every spliced-proc reference to module
  state is manually spelled; the sanctioned workaround is documented,
  a hygiene ask not a wall.
- **Focus/z-order layering, images/kitty graphics, OSC52, bracketed
  paste beyond what libvaxis decodes** — not in the stated purpose or
  the walls docs; binding or widget work when they arrive.
- **libvaxis pinned to a git hash** — supply-chain posture, not a
  toolchain surface.

## Commission recommendation

**One small compiler item, then package work.** The wildcard-payload
arm-capture gap (`! each *` under nested transforms) is the only thing
the package demonstrably needed and couldn't spell — a capture-machinery
element-type inference, *compiler feature* cost class, small-to-medium.
The `i64 /` → `@divTrunc` emission is a *defect fix* (pin it, fix the
emitter) — cheap and the honest close of the spinner walls' own record.
Everything else the stated purpose touches is already shipped or is
ordinary widget/transform work inside the package. No stdlib surface
and no new transform machinery are needed — vaxis already exercises
`claims_descendants`, `[pre]`, and `! wait` successfully.
