// MIRROR of 640_014_scan_no_match: `std/regex:scan` relocated into an imported
// module.
//
// regex is a SYNTHESIZING library — it appends a compiled-automaton declaration
// and then refers to it by a minted name. That name is where the entry-file
// assumption lives: four different module names collapse into one in the entry
// file, so a name minted from the wrong domain is indistinguishable from a
// correct one until the declaration lands in a module.
import app/lib

app/lib:run()
