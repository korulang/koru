// A cap() gate atom consults a capability grant — `--cap=<name>` flags
// carry grants (name=value provider atoms). A consult no grant covered is
// undeclared capability use: refused by the cap audit, the 310_145
// bare-flag audit's mirror (claimed_caps sink in comptime_eval).
import std/io

[cap(fs)]import std/io

std/io:print.ln("x")
