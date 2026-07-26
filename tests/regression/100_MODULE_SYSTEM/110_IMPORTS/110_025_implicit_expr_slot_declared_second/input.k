// Declaration ORDER does not select the implicit expression slot — the
// parameter's TYPE and NAME do. Here `expr: Expression` is declared after
// `invocation`, and the bare argument still lands in it.
//
// This is the wall against binding the slot by declaration position: that
// would pass 110_023 and silently break any transform that declares `expr`
// anywhere but first.
import app/lib

app/lib:go()
