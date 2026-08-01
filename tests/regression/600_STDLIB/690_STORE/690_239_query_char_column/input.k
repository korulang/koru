// 690_239 — a char[N] column read through `query`, the read-now verb.
//
// TASK #6, the last of the three query-side read gaps. The other two closed
// during the sweep->query migration and are green: `when` guards on a query
// arm (690_084) and a query arm writing the row it stands on (690_083). This
// one did not, because nothing exercised it: 690_052 pins this exact store on
// `rule` and passes, and its own comment even claims the query spelling —
// "Read path: `query { entity.label }` binds the bytes up to the first NUL" —
// but the file only ever ran `rule`. A capability documented in a passing
// test's prose and never executed by it.
//
// Today the emitted Zig does not compile:
//
//   error: array literal requires address-of operator (&) to coerce to slice
//          type '[]const u8'
//
// The query projection binds the column cell RAW —
//
//   const __koru_srf_e_L15_label = __koru_store_todos.label[__koru_si];
//
// which is the `[16]u8` array, while the body's Input declares that field as
// `label: []const u8`. Array where a slice is wanted; hence the error.
//
// THE SITE, and it is one conditional:
//
//   store.kz:7407  the ARM projection, emitted unconditionally:
//       "const {s} = __koru_store_{s}.{s}[__koru_si];"
//
//   store.kz:2991  the RULE projection, which already branches on it:
//       if (field_char_caps[pfidx] != null)
//           "const {s} = @import(\"std\").mem.sliceTo(&__koru_store_{s}.{s}[__koru_r], 0);"
//       else
//           "const {s} = __koru_store_{s}.{s}[__koru_r];"
//
// The rule path threads `field_char_caps` into `colRead(..., is_char)` and
// slices to the first NUL; the arm path (`SRewrite`, store.kz:6782+) never
// receives `char_caps` at all. The arm emitter's own comment at 7346 claims
// "scalars/char project the value type directly" — which is exactly the bug,
// since for char[N] the declared type is a slice and the emitted value is an
// array.
//
// So this is the store's recurring shape once more: two lowerings of one
// proc-visible contract, and a capability that reached only one of them. The
// membrane concept that predicted the 400_180/182 family predicts this too.
//
// MUST_RUN, red until the projection learns the char-column read. Expected
// output is byte-for-byte 690_052's, because it is the same store and the
// same rows — only the verb differs.
import std/io
import std/store

std/store:new(todos, capacity: 8) { done: i64, label: char[16] }

std/store:insert(todos) { done: 0, label: "buy milk" }
| row _ |> std/store:insert(todos) { done: 1, label: "ship koru" }
    | row _ |> _

std/store:query(todos)
! query e |> std/io:print.ln("[{{ e.done:d }}] {{ e.label:s }}")
