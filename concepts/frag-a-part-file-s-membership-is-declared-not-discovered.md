---
type: belief
id: frag-a-part-file-s-membership-is-declared-not-discovered
provenance: gated-part session 2026-10-21 — `~[build == macos]part` added so
  `index.macos.kz`/`index.win32.kz` can carry per-platform bodies; the
  directory-module scan was found double-loading the file as a submodule
ts: 2026-10-21
---

# A `stem.tag` file's membership is declared, not discovered — dormancy is a legal state (belief)

A `stem.tag.<ext>` file sitting next to `stem.<ext>` in a directory module
is part namespace, full stop. It joins the module only through the stem's
own `~part tag` declaration — never because the file exists. Before this
ruling, the directory-submodule scan read existence as identity:
`index.macos.kz` loaded as submodule `host.index.macos` *and* merged as
`index`'s part, so its procs were stamped with the wrong module and died
KORU050 against the module's own declarations. File modules never noticed —
they have no directory scan — so the collision waited for the first
directory module to carry a part.

Gated parts (`~[entries]part tag`) make dormancy *required*, not merely
tolerated: `index.win32.kz` must sit in the repo on every platform and mean
nothing on a build where its gate is off. If the fallback identity for an
unclaimed `stem.tag` file is "submodule," a gate-excluded platform file
still compiles on every other platform — the worst of both worlds. So the
scan now yields `stem.tag` to part namespace unconditionally, declared or
not, joined or not. An undeclared `stem.tag` file is dormant bytes, not an
error — the loudness lives where it belongs: declared-tag-without-file is
KORU201, and the gate itself reports every exclusion with provenance.

## The gate is a surface, not an import feature

The `~[entries]` annotation gate decides *AST membership* — it runs at
parse and decides what the program contains. `import` was its first
consumer and `part` is its second; the vocabulary (bare flag atoms,
comparisons, `and/or/not`, `flag()/cflag()/env()/command()`) is shared, the
KORU150 "must evaluate" contract is shared, and the only thing that
differed is the noun in the diagnostic. Any future declaration that decides
membership — conditional tors, conditional imports-of-impl, anything whose
presence is platform- or profile-shaped — should ride the same gate rather
than grow a parallel mechanism. Entries that cannot evaluate refuse; an
inert entry is silent gating, and silent gating is the failure the wall
exists to prevent.

## What follows

- **OS bodies ride `build=<os>` flags.** `koruc` already injects
  `build=<os tag>` into the flag set, so `~[build == macos]part macos`
  selects `index.macos.kz` with no new axis. A platform part file carries
  only what the stem's preamble does not — the merged module is one scope.
- **Dormant files are not dead code; they are unselected variants.** A
  reader who sees `index.win32.kz` on macOS should read it as "the Windows
  body, asleep" — the declaration that would wake it is in `index.kz`,
  behind `build == win32`.
- **Existence-based discovery is the failure class.** Any scanner that
  assigns identity from a filename pattern must check whether a
  declaration-based mechanism already owns that pattern. The tag stem was
  claimed twice; the declaration wins.

Pinned at 140_031–140_034: flag-on join, flag-off dormancy, declared-miss
KORU201 through the gate, and part-file-not-submodule in a directory
module — all green; 140_021 (ungated parts) and 310_027 (the import gate)
unchanged.
