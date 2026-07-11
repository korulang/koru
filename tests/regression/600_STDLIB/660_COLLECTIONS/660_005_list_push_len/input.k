// Step 1: push (void mutation, borrow) + len (read, borrow) + free (consume).
// Two pushes then len observes the growth → "len=2". xs stays <list!> through
// the borrows and is discharged by free. Uses the `len` event (the `xs.len`
// expression form is a separate bridge).
import std/io
import std/list

std/list:new-i64()
| list xs |> std/list:push(xs, v: 3) |> std/list:push(xs, v: 4) |> std/list:len(xs): n |> std/io:print.ln("len={{ n:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
