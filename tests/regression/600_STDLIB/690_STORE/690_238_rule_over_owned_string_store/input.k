// PIN (documented gap, red on purpose): a RULE over a store with an owned
// string column loses the row binding's phantom state.
//
//   error[KORU030]: argument 's' has no tracked phantom state,
//                   but event requires one of '<view|instance>'
//
// The row binding `e` reaches the rule body through the qrow/qbody transplant,
// and the owned column's `<instance>` does not travel with it. The READ path
// has no such problem — this exact file with `query` / `! query` in place of
// `rule` / `! row` builds and prints `new`, which is 690_062.
//
// WHY THIS EXISTS. 690_062 and 690_064 were red for precisely this reason,
// written as `query` back when `query` meant the rule. The store rename made
// `query` the read, and both went green WITHOUT THEIR SOURCE CHANGING A BYTE —
// same spelling, different verb. That is a legitimate pass (neither has writes
// after the site, so the rule's standing half was always dead weight, and they
// are reads), but it silently retired the only coverage this defect had. Two
// reds turning green is a pleasant number and was very nearly the whole story.
// The defect is still there.
//
// Flips to green when the transplant carries owned-column phantoms.
import std/io
import std/string
import std/store

std/store:new(names, capacity: 8) { label: *std/string:String<std/string:instance!> }

std/string:from-page(text: "old")
| ok s |> std/string:take(s): owned |> std/store:insert(names) { label: owned }
    | row r |> std/string:from-page(text: "new")
        | ok s2 |> std/string:take(s: s2): owned2 |> std/store:stored { names[r].label: owned2 }
        | err _ |> _
| err _ |> _

std/store:rule(names)
! row e |> std/string:read(s: e.label): text |> std/io:print.ln("{{ text:s }}")
