// MIRROR of 320_093_print_blk_void_chain_inline_second: `std/io:print.blk`
// relocated into an imported module.
//
// print.blk carries a SOURCE BLOCK rather than an argument list, so it pins
// whether a transform whose payload is captured source text survives
// relocation — a different intake path from 115_001's ordinary call.
//
// The one-line block form is deliberate: a source block that OPENS on a
// subflow-definition line and closes later is refused by the parser regardless
// of modules, which 115_017 holds. Closing on the same line keeps that gap out
// of this arm so a failure here means the module boundary.
import app/lib

app/lib:run()
