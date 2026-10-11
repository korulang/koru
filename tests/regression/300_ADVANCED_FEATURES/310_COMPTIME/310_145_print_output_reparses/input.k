// `koruc --print` emits "canonical Koru source from the post-parse AST", but
// the canonical form cannot be re-parsed as .k: on this file it prints `~`
// spellings (a .k file gets no tilde — PARSE003 on re-read) and prepends the
// compiler-env import the source never wrote. A canonical print that the
// compiler cannot read back in the source's own facet is not canonical.
// Pin: --print output of a .k parses as .k, of a .kz parses as .kz.

import std/io

std/io:print.ln("round-trip me")
