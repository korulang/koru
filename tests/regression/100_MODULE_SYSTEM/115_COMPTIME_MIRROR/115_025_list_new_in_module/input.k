// MIRROR of 660_003_list_len_in_expr: `std/list:new` with a push, a len read in
// an interpolation expression, and a free, relocated into an imported module.
//
// The list handle carries an obligation, so this also pins that a discharge
// chain stays intact when the whole flow is a module tor body rather than a
// top-level statement.
import app/lib

app/lib:run()
