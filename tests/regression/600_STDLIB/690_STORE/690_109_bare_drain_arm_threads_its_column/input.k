// The drain arm names nothing, and its column threads into the drain call.
//
//     ! discharge |> app/lib/pend:cancel()
//
// At ONE owned column the arm's payload IS the value (arity picks the payload
// shape), and the drain call has exactly one unfilled parameter of exactly that
// type — so there is one candidate for one slot, and the by-type fill
// (210_191/192/194) has one reading. Naming a binder buys nothing here: it exists
// only to be written twice, once to bind and once to pass.
//
// This is the last position in the one-column arc still holding a name. The
// declaration spells the column bare, `| item` and `| full` hand back the value,
// and a one-column store's watch arm IS the store (690_102/103). The drain arm's
// binder is the same shape one step further in.
//
// The column carries <open!> and `cancel` consumes <!open>, so the fill IS the
// disposal — there is no separate binding left over to auto-discharge.
//
// BOUNDARY: this is a one-column rule. At two columns the payload is a record and
// the name is how a column is reached, which 690_097 pins with
// `! discharge item |> commit(item.tx)`.
//
// 690_106 is this program with a binder and a written label; 690_107 is the
// halfway spelling that binds and then omits the label. Whether a binder stays
// LEGAL-but-unnecessary at one column or becomes refused the way a named column
// is refused on a watch arm is a separate ruling; this pin only says the bare
// form threads.
import std/io
import std/store
import app/lib/pend

std/store:new(batch, capacity: 2) { *app/lib/pend:Pending<open!> }
! discharge |> app/lib/pend:cancel(): n |> std/io:print.ln("cancelled {{ n:d }}")

app/lib/pend:start(): p |> std/store:insert(batch) { p }
    | row _ |> _

std/io:print.ln("inserted")
