// PIN (documented gap, red on purpose): a NAMED store field holding a
// CROSS-MODULE obligation loses its phantom through the `| full` rejection
// record — `f.t` reports "no live '<held!>' obligation" even though the
// full arm hands back exactly the row insert refused, obligations and all.
//
// The contrast that makes this a gap and not a rule: the SAME shape with a
// same-module obligation tracks fine — todo_tui's
//   | full f |> std/string:free(s: f.label)
// compiles today (std/string's `instance`), and so does this file with
// `*std/string:String<instance!>` in place of the lib type. Only the
// cross-module phantom (`app/lib/res:held` here; koru/sse's `framing` and
// koru/curl's `open` in the wild) drops out of the record.
//
// Until fixed, the working idiom is the ANONYMOUS single-field store
// (downloads' batch): the rejection payload IS the value, and the tracker
// follows it. Found by kopium's framer store (c_chat_pane.k), which speaks
// that idiom for exactly this reason.
//
// When the tracker learns record fields, this flips to MUST_RUN.

import std/store
import app/lib/res

std/store:new(box, capacity: 2) { t: *app/lib/res:Thing<held!> }

tor arm {}
arm = app/lib/res:mk(): t |> std/store:insert(box) { t }
| row _ |> _
| full f |> app/lib/res:drop(f.t)

arm()
