// A residual is DATA in the AST, not a step in the flow.
//
// Both dispositions are declared, and the program's own output is unchanged by
// their presence — `[norun]` means the declaration never executes. That is what
// lets a residual live beside the code it describes without costing the program
// anything at runtime.
//
// The two tors are separate because the NAME carries the whole semantic: `owed`
// closes when someone BUILDS the thing, and names the test that decides it;
// `doubted` closes only when someone RULES on whether the thing should exist at
// all. Nothing but the name distinguishes them, and nothing else needs to.

import std/io
import std/todo

std/todo:owed {
  "name": "example-owed",
  "site": "src/example.zig:1",
  "owed": "A residual that someone must build, and a test that decides when they have.",
  "witness": "675_001_invariants_declare_without_executing",
  "tags": ["example"]
}

std/todo:doubted {
  "name": "example-doubted",
  "question": "Should the example feature exist at all?",
  "evicts": "The example residual above, and the stub it names.",
  "tags": ["ruling"]
}

std/io:print.ln("flow ran once")
