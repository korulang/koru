---
type: frag
id: frag-an-obligation-label-reaches-any-module-that-can-name-its-disposer
provenance: koru smelt 2026-09-06, corrected from a same-session misdiagnosis
ts: 2026-09-06
---

# An obligation label reaches any module that can name its disposer

A fresh obligation label (`string<mine!>`) minted by a `~pub tor speak` in
module A discharges from module B — both explicitly (`lib:drop(t: s)`) and via
auto-discharge — as long as B imports A and the disposer is public.

This CORRECTS a same-session misdiagnosis (2026-09-06): an earlier assertion
that "fresh labels do not travel, only the shared `allocated!` house label
does" was WRONG. The observed `koru.yyjson:copied` vs consumer-homed mismatch
was a misnesting artifact of the failing flow, not a label-reachability
defect. The yyjson copy chose the shared `allocated!` label for a different,
valid reason (house convention with read-file), which does not imply fresh
labels were broken.

What would correct this belief: a consumer module that imports the minting
module and CANNOT discharge a fresh label — compile error or mismatch —
with a clean minimal repro.

Pinned: tests/regression/600_STDLIB/660_LABELS/660_040_fresh_label_cross_module
(both explicit and auto discharge paths green).

Evolved 2026-11-26 (rational-kit): the reach extends to *parameter
position* — a tor in module B can declare a parameter that CONSUMES a
foreign obligation, spelled `string<std/io:!allocated>`: the bang sits
inside the namespaced tag. Bare `<!tag>` in a param is always
module-local (resolves to B's own tag), and `string<mod:tag!>` on an
input is refused as an attempt to issue (KORU033). Pinned in practice:
`std/linalg:ingest-owned { s: string<std/io:!allocated> }` consumes
io-allocated canon text with no copy — exercised by 615_090.