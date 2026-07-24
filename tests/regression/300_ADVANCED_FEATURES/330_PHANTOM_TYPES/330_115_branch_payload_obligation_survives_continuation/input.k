// The CONTROL for 330_113/330_114, and the reason they are interpretable.
//
// Identical obligation, identical continuation, delivered as a BRANCH PAYLOAD
// (`| lit lamp`) instead of a `:` bind. This one IS caught. A branch arm gets a
// terminal validation of its own scope in validateContinuation; the flow head's
// root_context gets no equivalent check at flow exit.
//
// Keep this green. It is what makes 330_113 a defect rather than a design: the
// two spellings bind the same obligation and must enforce identically, so the
// day 330_113 goes green this test must still be green. If a fix makes THIS one
// red it moved the hole rather than closing it.
import std/io
import app/lantern

app/lantern:light()
| lit lamp |> std/io:print.ln("in the dark")
| dud |> _
