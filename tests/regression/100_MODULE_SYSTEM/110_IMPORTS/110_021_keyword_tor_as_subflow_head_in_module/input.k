// RED BY DESIGN (pinned 2026-07-25). A keyword tor (`cond`, `if`, …) used as a
// subflow's DEFINITION HEAD resolves only in the ENTRY file. Inside an imported
// module it is looked up in that module's own namespace and fails:
//
//   error[KORU040]: unknown tor 'app.pick:cond'
//
// SHOWN 2026-07-25, all cells — the axis is ENTRY vs MODULE, not file kind:
//   definition head, entry .k        -> WORKS  (`pick = cond(n)` prints 20)
//   definition head, module .k       -> FAILS  (this pin)
//   definition head, module .kz      -> FAILS  (identical error)
//   definition head, module + explicit `import std/control`  -> FAILS
//   pipeline step,   module .kz      -> WORKS  (corpus: 910_LANGUAGE_SHOOTOUT/
//                                       nbody/koru/kernel_pairwise.kz calls
//                                       bare `for(0..iterations)`)
// `.k` vs `.kz` makes no difference and neither does importing std/control.
// Pipeline-position keyword tors are fine; only the definition head misresolves.
//
// Why it matters: it blocks decomposing an app into modules. Found trying to
// split koru-examples/gallery.k, where every per-page key vocabulary is
// `name = cond(ch)`. Those cannot move out of the entry, so a TUI app is forced
// to stay one file. The module system already works for value tors — see
// koru-examples/ledger, a three-file program with a transitive hop — so this is
// specifically the FLOW vocabulary that cannot be modularised, which is most of
// what an app is made of.
import std/io
import app/pick

app/pick:pick(n: 2): v |> std/io:print.ln("v={{ v:d }}")
