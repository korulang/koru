// MIRROR of 430_044_runtime_run_budget: `std/runtime:register` declaring a
// priced scope inside an imported .kz module, with the interpreted run that
// draws on it.
//
// The registered scope names a tor of the module and prices it, and the source
// string resolves that name at run time through the registry the transform
// built. A scope registered under the wrong home would leave the name
// unresolvable rather than mispriced.
import app/lib

app/lib:run()
