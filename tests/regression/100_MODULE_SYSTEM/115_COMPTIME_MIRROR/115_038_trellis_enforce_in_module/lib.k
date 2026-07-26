import std/trellis
import std/io

std/trellis:define("kernel-shape")
| `std/kernel:init/kernel/.*` _ => ok
| `.*std/kernel:pairwise` _ => error "std/kernel:pairwise found outside std/kernel:init"
| `.*std/kernel:self` _ => error "std/kernel:self found outside std/kernel:init"

std/trellis:enforce("kernel-shape")

pub tor armed {}
armed = std/io:print.ln("law armed")
