// Self-contained pure-Koru Hello World via a module-level `const {}` block.
//
// `const` is a Koru keyword (control.kz). The block form with NO `| as`
// continuation declares module-scope constants that lower per-target
// (`const name = "Claude";` etc.), so the following flow can interpolate them
// directly — no host-side companion file needed.
//
// Pins the module-declaration form specifically, as distinct from the
// config-capture form (`const(...) | as cfg |> ...`): the bare block must
// declare `name`/`count` at module scope for the flow to interpolate them.
import std/io

const {
    name: "Claude"
    count: 42
}

std/io:print.ln("Hello, {{ name:s }}! The answer is {{ count:d }}.")
