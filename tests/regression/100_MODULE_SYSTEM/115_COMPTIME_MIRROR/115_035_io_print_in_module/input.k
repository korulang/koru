// MIRROR of 630_001_io_println_cross_target: `std/io:print` — the newline-less
// sibling of print.ln — relocated into an imported module.
//
// 115_001 pins print.ln; this pins print, which carries its own `|zig`/`|js`
// variants. Both are site-local, so the pair is the control that says the
// module machinery is not what any red on this wall is measuring.
import app/lib

app/lib:run()
