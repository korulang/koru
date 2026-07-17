// Test: phantom state on primitive types — units-of-measure shape (F# syntax).
//
// `f32<celsius>` and `f32<fahrenheit>` are distinct phantom-labelled primitives.
// A converter event declares the transition at its boundary: in `<celsius>`,
// out `<fahrenheit>`. The phantom checker enforces both ends. (No `!` —
// primitives have no cleanup obligation; these are pure labels.)
//
// This is the first test migrated to the F#-style `<...>` phantom syntax.
// Other phantom tests still use the legacy `[...]` form (parser accepts both
// during transition).

import std/io

event read-temp { sensor_id: u8 } -> f32<celsius>

read-temp -> 22.5

event to-fahrenheit { c: f32<celsius> } -> f32<fahrenheit>

to-fahrenheit -> c * 9.0 / 5.0 + 32.0

read-temp(sensor_id: 1): c |> to-fahrenheit(c): f |> std/io:print.ln("{{ f:f }} F")
