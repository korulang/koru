---
type: belief
id: frag-absence-claims-are-falsified-by-how-you-grep
provenance: falsified live during the assay-yq judging (2026-11-05) — a case-sensitive `grep -rln yaml` missed the tracked `~/src/koru-libs/yaml/` libyaml lift, and the absence claim went into the map load-bearing
ts: 2026-11-05
---

# Absence claims are falsified by how you grep

Belief: a "nothing exists" line in a map or review is only as honest as
the survey behind it — and a case-sensitive content grep is not a
survey. `~/src/koru-libs/yaml/` sat tracked since 2026-08-03 (index.kz,
README, examples, tests) while `grep -rln yaml` found only doc
mentions: the package's own files spell `YAML` and the directory name
itself never appears inside file contents.

The measured fixes, cheapest first:

- `git ls-files | grep -i <stem>` per repo — the tracked name list is
  the ground a content grep never sees.
- `ls <pkg-root>` on the libs root — directory names are surfaces.
- Case-insensitive content grep (`-i`) for anything named in English.

The assay discipline's own rule held: "an unprobed gap is an unmeasured
one" extends to absence — an unsurveyed absence is an unmeasured one.
The judging caught it the same day; the map was revised, not
evaporated. When asserting absence, name the instrument used to look.
