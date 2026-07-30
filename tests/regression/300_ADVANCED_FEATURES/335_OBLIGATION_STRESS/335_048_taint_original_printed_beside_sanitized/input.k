// PIN (outside-in finding): the developer sanitizes CORRECTLY — binds the clean
// result and uses it — and then also prints the tainted original beside it.
// Both reach the sink. This is the sharper twin of 335_047: there is no dropped
// value and no unused binding here, so nothing incidental catches it.
//
// Why the twin matters: in the shape where the clean binding is bound but never
// read, `KORU100: unused binding 'clean'` fires for entirely unrelated reasons
// and masks the hole. Read `clean` anywhere at all — as here — and the tainted
// print sails through. Any fix must be measured against THIS file, not just 047.
//
// Observed (2026-07-30): accepted, `./a.out` prints
//   clean=Hello, World! tainted=Hello, World!
// The second interpolation slot reads a binding whose <tainted!> obligation was
// already discharged by `validate-response`. That read must be rejected with the
// same diagnostic 335_024/335_025 raise for a stale resource binding.
//
// Note the interpolation angle: `{{response:s}}` is a binding read inside a
// string-literal argument. It is already visible to at least one analysis —
// KORU100 counts `{{clean:s}}` as a use of `clean`, which is why no unused-
// binding error fires here. So the read is seen; the disposal check is what
// does not run on it. See 335_047 for the suspected site.
//
// Grounding:
//   - obligation on a primitive string:  330_068/input.k:14
//   - sanitizer accepting <!label>:      330_068/input.k:18-20
//   - bind sanitizer result then use it: 330_068/input.k:22
//   - Use-after-discharge diagnostic:    335_024/input.k:18, 335_025
//   - primary sibling pin:               335_047
import std/io

tor get-from-network {} -> string<tainted!>
get-from-network -> "Hello, World!"

tor validate-response { response: string<!tainted> } -> string
validate-response -> response

get-from-network(): response
|> validate-response(response): clean
|> std/io:print.ln("clean={{clean:s}} tainted={{response:s}}")
