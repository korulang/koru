// The capacity-1 twin of 690_100: a ONE-column singleton names no field either,
// so the store's name IS the lvalue and the reader.
//
//     std/store:new(counter) { v: 0[i64] }   ->   std/store:new(counter) { 0[i64] }
//     std/store:stored { counter.v: 5 }      ->   std/store:stored { counter: 5 }
//     {{ counter.v:d }}                      ->   {{ counter:d }}
//
// 690_086's rule 3 said a capacity-1 store's name IS its only row, which is why
// `ui.done` and `e.v` are the same shape. That still holds — this narrows what
// sits on the right of the dot to nothing when there is only one column.
//
// The `n` in the literal text of "n {{ counter:d }}" must survive: a bare store
// reference is rewritten only inside `{{ … }}`, never in prose.
import std/io
import std/store

std/store:new(counter) { 0[i64] }

std/store:stored { counter: 5 }
std/io:print.ln("n {{ counter:d }}")
std/store:stored { counter: counter + 2 }
std/io:print.ln("n {{ counter:d }}")
