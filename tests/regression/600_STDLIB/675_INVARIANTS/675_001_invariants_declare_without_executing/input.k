// An invariant is DATA in the AST, not a step in the flow.
//
// Both dispositions are declared, both carry prose no algorithm could check,
// and the program's own output is unchanged by their presence — `[norun]`
// means the declaration never executes. That is what lets a rule live next to
// the code it constrains without costing the program anything.
//
// The two tors are separate because the NAME is the whole semantic: `inferred`
// is permanent by nature and its growth is good; `aspirational` is debt by
// construction and its growth is a smell. Nothing but the name distinguishes
// them, and nothing else needs to.

import std/io
import std/invariants

std/invariants:inferred {
  "name": "comment-language",
  "tags": ["git-gate"],
  "rule": "Comments are written in English, not Norwegian."
}

std/invariants:aspirational {
  "name": "no-silent-truncation",
  "tags": ["git-gate"],
  "rule": "No emitter drops elements without a diagnostic."
}

std/io:print.ln("flow ran once")
