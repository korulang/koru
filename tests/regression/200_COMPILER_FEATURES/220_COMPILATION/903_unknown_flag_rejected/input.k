// Pins: a flag koruc does not recognise must be REJECTED, not absorbed.
//
// The unknown-flag arm at main.zig strips the dashes and calls
// `compiler_config.addFlag` — every unrecognised token becomes a live compiler
// flag for the backend, with no diagnostic. A typo'd or invented flag therefore
// compiles clean and does exactly nothing, which reads as "the flag worked".
// `--no-auto-discharge` (not a flag; the real one is `--auto-discharge=disable`)
// silently produced an ordinary auto-discharge-ON build.
//
// The registry to validate against already exists and needs no new surface:
// `flag.declare` entries are collected from the imported AST by
// `collectFlagDeclarations`, which --help already uses, and which walks
// `module_decl` so a flag declared beside its own pass (compiler.kz's
// `auto-discharge=disable`) is visible. Validation is necessarily POST-parse —
// arg parsing runs before there is an AST to read — and matches on the whole
// token, since a declared name embeds its value (`auto-discharge=disable` is
// the name, not a name/value pair).
import std/io

std/io:print.ln("should not get here")
