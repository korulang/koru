// COVERAGE (kebab-stdlib-restructure): the call site spells the module with `/`,
// matching the import string and the filesystem (`std/io` = `std/io.k`).
// GREEN already — verified 2026-06-03 that `std/io:print.ln` parses and resolves
// (FLOW anchor emits `std/io:print.impl()`). So `/`-namespace is NOT new parser
// work; it already coexists with the `.` form. The remaining Track-A work is the
// corpus codemod (`.`→`/`) + eventually tightening `.` out of namespace position.
// (Written as .kz — the harness discovers tests by input.kz; pure-`.k` entry
// support was dropped with the const commit in the D5 rebase.)
import std/io

std/io:print.ln("slash namespace ok")
