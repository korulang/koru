// Self-contained pure-Koru Hello World via a module-level `const {}` block.
//
// `const` is a Koru keyword (control.kz). The block form with NO `| as`
// continuation declares module-scope constants that lower per-target
// (`const name = "Claude";` etc.), so the following flow can interpolate them
// directly — no host-side companion file needed.
//
// PINS THE GAP: today the `const` transform only implements the config-capture
// form (`~const(...) | as cfg |> ...`); the module-declaration form is
// unimplemented, so `name`/`count` never get declared and this fails.
import "std/io"

const {
    name: "Claude"
    count: 42
}

std.io:print.ln("Hello, {{ name:s }}! The answer is {{ count:d }}.")
