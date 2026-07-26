import std/trellis
import std/io

std/trellis:define("kernel-shape")
| `std/kernel:init/kernel/.*` _ => ok
| `.*std/kernel:pairwise` _ => error "std/kernel:pairwise found outside std/kernel:init"
| `.*std/kernel:self` _ => error "std/kernel:self found outside std/kernel:init"

pub tor verdict {}
verdict = std/trellis:check("kernel-shape")
| ok |> std/io:print.ln("categorized: kernel-shape")
| error msg |> std/io:print.ln(msg)
