// A callee that declares NO `expr: Expression` must have its bare arguments
// left as puns. `take-word(word)` puns onto the `word` parameter and stays
// that way — the implicit expression slot exists only where a parameter of
// type Expression is declared.
//
// This is the guard on the other side of 110_023: a slot rule that remaps bare
// arguments without first checking the callee declares the slot would rewrite
// this pun and destroy the binding.
import app/lib

app/lib:go(word: "hi")
