// 820_005 — mail merge: one `{{key}}` template rendered once per row of a
// recipients store, each `{{key}}` replaced by that row's bound value.
//
// The table is a std/store whose rows OWN their names (*String<instance!>
// columns): custody moves in on insert, query borrows each row read-only,
// and teardown frees every live element. The renderer is two subflows —
// `merge` splits the template on "{{" and routes each piece; `emit` maps a
// placeholder key to the current row's value. A piece with no `key}}` shape
// (the leading literal) appends verbatim; a piece whose key binds no field
// gets `{{` + piece re-appended untouched — unknown placeholders pass
// through, the way a real merge leaves unfilled slots visible.
//
// Split is a proc-effect: its `! piece` arm lowers to a context-free fn
// that sees module scope only — not even a subflow's own params cross into
// it — so the current row crosses by IDENTITY: `! query`'s `[ordinal]` names
// the row's position in the walk, a scalar singleton `curi` stages it (the
// pstate idiom — the one surface a `fn piece` body can read), and `emit`
// re-finds that same row in its own `! query` by matching ordinal. The
// output buffer crosses the same boundary the 690_190 way: a `docs` store
// cell appended through a borrow of its live row.
import std/io
import std/string
import std/regex
import std/store
import std/fmt

std/store:new(recipients, capacity: 4) { name: *std/string:String<std/string:instance!>, credits: i64 }
std/store:new(docs, capacity: 2) { doc: *std/string:String<std/string:instance!> }
std/store:new(curi) { ri: 0[i64] }

// Append `text` to the document buffer — the docs store's single live cell.
tor out.append { text: string<*@scoped> }
out.append = std/store:query(docs)
! query d |> std/string:append(s: d.doc, text)
    | ok |> _
    | err _ |> _

// Emit one placeholder piece against the row staged in `curi`: a known key
// appends the row's bound value then the piece's remainder; an unknown key
// re-appends `{{` + the raw piece (restoring `{{key}}rest` verbatim).
tor emit { key: string, rest: string, p: string }
emit = std/store:query(recipients)
! query { [row]rr, [ordinal]orn } |> if(orn == curi.ri)
    | then |> if(key == "name")
        | then |> std/fmt:ln("{{ rr.name:S }}"): v |> out.append(v.text) |> out.append(text: rest)
        | else |> if(key == "credits")
            | then |> std/fmt:ln("{{ rr.credits:d }}"): v |> out.append(v.text) |> out.append(text: rest)
            | else |> out.append(text: "{{") |> out.append(text: p)

// Render template `t` into the docs buffer. Splitting on "{{" leaves the
// leading literal as piece 0 and every placeholder as a `key}}rest` piece;
// a literal piece can never match the key regex, so no piece counter is
// needed.
tor merge { t: string }
merge = std/string:split(s: t, sep: "{{")
! piece p |> std/regex:match(p)
    | `(?<key>[a-z]+)}}(?<rest>.*)` { key: string, rest: string } |> emit(key, rest, p)
    | no-match |> out.append(text: p)
| done _ |> _

std/string:from-page(text: "")
| ok b |> std/string:take(s: b): buf |> std/store:insert(docs) { doc: buf }
    | row _ |> _
| err _ |> _

std/string:from-page(text: "ada")
| ok s |> std/string:take(s): n |> std/store:insert(recipients) { name: n, credits: 420 }
    | row _ |> _
| err _ |> _

std/string:from-page(text: "grace")
| ok s |> std/string:take(s): n |> std/store:insert(recipients) { name: n, credits: 1337 }
    | row _ |> _
| err _ |> _

std/string:from-page(text: "edsger")
| ok s |> std/string:take(s): n |> std/store:insert(recipients) { name: n, credits: 7 }
    | row _ |> _
| err _ |> _

// Per row: stage the row's ordinal in `curi` (scalar singleton — the one
// surface a proc-effect arm can read), clear the buffer, merge, print.
std/store:query(recipients)
! query { [row]_, [ordinal]rn } |> std/store:stored { curi.ri: rn } |> std/store:query(docs)
    ! query d |> std/string:clear(s: d.doc) |> merge(t: "Dear {{name}}, your balance is {{credits}} credits. Ref: {{mystery}}.") |> std/io:print.ln("{{ d.doc:S }}")
