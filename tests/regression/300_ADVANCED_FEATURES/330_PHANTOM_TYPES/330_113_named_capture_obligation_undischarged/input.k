// Pins: an obligation captured into a NAMED binding and then never consumed
// must be rejected, exactly as the bare-drop form already is.
//
// The bare drop `app/lantern:light()` mints `_auto_0` and 330_025's checker
// catches it: "Resource '_auto_0' carries obligation <lit!> was not
// discharged." Give the very same call a name and chain past it, and the
// obligation walks out of the program unexamined — `lamp` is bound, `<lit!>`
// is live at end of flow, and the compile succeeds.
//
// The capture is the only difference between this file and the accepted one.
// Auto-discharge is disabled here so the wall itself is under test rather
// than the LIFO insertion that normally hides the question.
import std/io
import app/lantern

tor delve { room: i64 }

delve = if(room > 4)
| then |> std/io:print.ln("You climb back into daylight.")
| else |> delve(room: room + 1)

app/lantern:light(): lamp |> delve(room: 0)
