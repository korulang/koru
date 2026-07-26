// MIRROR of 320_093_print_blk_void_chain_inline_second: `std/io:print.blk`
// relocated into an imported module.
//
// print.blk carries a SOURCE BLOCK rather than an argument list, so it pins
// whether a transform whose payload is captured source text survives
// relocation — a different intake path from 115_001's ordinary call. The block
// opens on the subflow-definition line, the position 210_166 pins.
//
// The original's second chained block is left out on purpose: a `|>` tail after
// a multi-line block on a definition line is dropped, held by 210_167 in the
// entry file. Riding it here would make this arm red for a reason that is not
// the module boundary.
import app/lib

app/lib:run()
