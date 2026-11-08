// `caps` collects cap(...) annotation entries — declarations the module
// makes about its own effect surface — and `caps <subject>` walks the
// declaration's implementation downstream through flow impls, reporting
// every reached node's declared caps with provenance. Declarations live
// on procs (the only effect-bearing nodes); contract-level entries on the
// tor are an optional summary tier. Scan hits are the inferred tier:
// lexical, comments and strings count, never proof.
//
//   koruc <file> caps           # census: every decl with entries or hits
//   koruc <file> caps job       # tree: job's impl reaches fetch's caps
//   koruc <file> explain        # std/caps explainer section

import std/caps

[
- cap(io|network)
  contract claims network io
]tor fetch { url: string } -> string

tor churn { n: u64 }
| done u64
| failed string

tor job { url: string } -> string

job = fetch(url)
