// MIRROR of 640_006_match_groups_whole_binding: `std/regex:match` with a
// grouped pattern and whole-payload binding, relocated into an imported module.
//
// 115_003 pins `regex:scan` on the boundary; this pins `match`, the library's
// other entry point, because the two synthesize their automaton through
// different paths and one can hold while the other does not.
import app/lib

app/lib:run()
