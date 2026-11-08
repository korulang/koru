// Pins: whole-line comment blocks are first-class `.comment` AST items —
// they must not disturb parsing, printing, or emission. Every shape below
// is legal trivia: header runs, doc blocks above decls, blank-separated
// groups that merge into one block, and trailing notes that stay invisible.

import std/io

// ask prints its input line back.
// The doc block above a decl is ONE .comment item — blank lines inside
// the run are preserved in its content, not item boundaries.

tor ask { line: string }

// section banner — separated from the doc above by code, so its own block

std/io:print.ln("comments survived") // trailing note: not an item
