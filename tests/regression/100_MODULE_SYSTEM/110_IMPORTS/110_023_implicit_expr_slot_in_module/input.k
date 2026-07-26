// The implicit expression slot, filled from inside an IMPORTED MODULE. The
// bare `hello` must reach the transform's AST as the `expr` argument exactly
// as it does from the entry file (110_024) — where the invocation lives is not
// part of the rule.
//
// The transform reads the slot back off `invocation.args` BY NAME, so this
// pins the AST binding rather than the proc parameter, which the emitter fills
// positionally and which would otherwise mask an unbound argument.
//
// No stdlib is involved: `app/lib2` is an ordinary user library. 690_079 holds
// the same shape for `std/store`.
import app/lib

app/lib:go()
