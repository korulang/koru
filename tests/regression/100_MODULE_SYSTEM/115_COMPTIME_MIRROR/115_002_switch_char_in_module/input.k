// MIRROR of 645_001_char_single: `std/switch:char` dispatch relocated into an
// imported module.
//
// Site-local like io — the char dispatch rewrites its own invocation into the
// arms it was given. Second control arm: two independent site-local libraries
// agreeing that relocation is a no-op is what makes a synthesizing library's
// failure attributable to synthesis rather than to modules in general.
import app/lib

app/lib:run()
