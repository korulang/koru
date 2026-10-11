---
type: belief
id: frag-raw-text-scan-is-not-feature-detection
provenance: quirk-hunt second run, 2026-10-11 — a `//` comment containing
  `import std/compiler` satisfied the injection check and broke every
  std/compiler: host-type reference downstream (310_147)
ts: 2026-10-11
---

# A substring scan over raw source counts prose as presence — feature detection belongs to the AST (belief)

The compiler-env import is auto-injected when the source does not already
contain it. The check is `indexOf(source, "import std/compiler")` — bytes,
not structure. A comment mentioning the import satisfies it exactly as well
as the declaration does, the import is never injected, and the failure
surfaces far away: KORU117 "unknown host type" inside `koru_std/io.kz`,
naming files the author never opened. The actual cause — seven words in a
comment — appears in no diagnostic.

Two states, one observation again: "the construct is present" and "the
construct's text is present" are indistinguishable to a byte scan. Comments
and string literals both defeat it, in both directions — prose *with* the
substring suppresses a needed injection; prose *without* it proves nothing
about absence of the real decl elsewhere.

The rule: if a check is asking "does the program declare X", the question is
a semantic one and the scan must happen after trivia is stripped — on the
AST, the token stream, or a parse-time symbol set. Raw-source `indexOf` is
only honest for questions about bytes ("does this file contain a shebang"),
and those are rare. The diagnostic asymmetry makes the cheap version
expensive twice: it fails silently at the scan site and loudly at a site
that cannot name the cause.
