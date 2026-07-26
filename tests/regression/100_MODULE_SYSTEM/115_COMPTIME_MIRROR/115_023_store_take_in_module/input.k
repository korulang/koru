// MIRROR of 690_075_store_cross_store_row_index: `std/store:take` indexed by a
// cell of a DIFFERENT store, both stores owned by the imported module.
//
// take discharges a row's obligation, and the index `todos[ui.sel]` has to
// lower against two separately synthesized stores that share one module home.
// The singular and plural store paths meet here, which is where a fix that
// converted only one of them would show.
import app/lib

app/lib:run()
