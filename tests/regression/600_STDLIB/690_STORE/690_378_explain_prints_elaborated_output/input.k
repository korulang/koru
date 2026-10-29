// `koruc explain` on a plain store — the `elaborated` section runs the
// real transform pass on a clone and prints what the pass wrote: the
// `std/store:new` site dissolved to a marker comment (emit-only IR), the
// insert/query sites rewritten to calls into minted tors, the SoA cell,
// and every `__store_*` decl the transform minted — the generated
// vocabulary the source never named, printed through ast_printer. The
// sweepbody impl flow is the pinned finding: the transform mints a flow
// the printer cannot spell (inline_body is transform-produced).
// post.sh drives the text rows; MUST_RUN proves the program still runs.
import std/io
import std/store
import std/explain

std/store:new(body, capacity: 4) { left: i64, right: i64 }

std/store:insert(body) { left: 10, right: 20 }

std/store:query(body)
! query e |> std/io:print.ln("left {{ e.left:d }}")
