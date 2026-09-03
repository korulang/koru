// A terminal declared through the proto door is a usable identity, not only a
// registered name. `std/proto:float(Health)` mints `Health`, emits its f64
// host lowering, and lets ordinary Koru events take and return it. The point
// is the contract that later compounds can share: `Health` names the same
// thing everywhere it is referenced.
import std/io
import std/proto

std/proto:float(Health)

pub tor report-health { health: Health } -> Health

report-health -> health

report-health(health: 98.6): value |> std/io:print.ln("health {{ value:d }}")
