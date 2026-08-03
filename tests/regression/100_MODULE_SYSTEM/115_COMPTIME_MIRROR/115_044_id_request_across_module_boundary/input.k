// PINS: `[id]` across a MODULE BOUNDARY, with a lexical capture — the exact
// combination the single-file `[id]` tests cannot reach.
//
// `[id]`'s synthesized value names the store's SoA cell, and the cell is
// declared in the store's OWN module. Every other reference the sweep loop
// emits carries a qualifier for that module; `[id]`'s did not, because the twin
// it was modelled on (`[ordinal]`) names no store and was safe by accident.
//
// THE COMBINATION IS THE BUG, and neither half reaches it alone:
//   - `[id]` in the entry file                     -> the loop is LIFTED into a
//     `__store_sweeprun_*` event placed in the store's own module, so a bare
//     `__koru_store_<s>` resolves by coincidence of placement (690_246);
//   - a capturing cross-module sweep with no `[id]` -> no store name is emitted
//     into the caller's namespace at all (115_043).
//
// A LEXICAL capture is what forces the loop to stay INLINE at the sweep site,
// which is the caller's namespace. `[id]` does not do that on its own: its
// value is computed from the cursor inside the loop, so it is deliberately not
// counted as lexical. `tick(): k` supplies the lexical half, and only then does
// the unqualified cell reference land somewhere it is not declared.
//
// Caught by review, not by the board: every request-annotation test in the tree
// is a single-file entry-module program, where the qualifier is `main_module.`
// and a bare name resolves anyway.
//
// The oracle carries both halves. `k` = 2 scales 10/20/30 to 20/40/60, proving
// the lexical capture arrived; the chain head is the LAST row visited, so
// reading it back through its handle yields 60, proving `[id]` named a row that
// can actually be addressed.
import std/io
import std/store
import app/lib/world
import app/lib/systems

app/lib/world:seed()
app/lib/systems:scale-and-link()
app/lib/world:peek()
