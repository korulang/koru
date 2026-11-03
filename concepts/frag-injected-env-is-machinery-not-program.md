---
type: belief
id: frag-injected-env-is-machinery-not-program
provenance: quirk-hunt pins 310_149-152 greened in one commit — four surfaces each treated the injected env import as program text
ts: 2026-11-03
---

# The injected compiler env is machinery, not program text

`koruc` prepends `import std/compiler` to every entry file so the stdlib's
`std/compiler:` transforms resolve. That line is the machine's — the program
never wrote it — and every surface that reads the program must keep the two
apart:

- **Detection is lexical, not textual.** "Already imported?" is a statement
  question: `import std/compiler` must open a line's statement. A comment or
  string mentioning it is not a declaration (310_152 — a mention suppressed
  injection and every `std/compiler:` host type in the stdlib failed KORU117).
- **Printing is what the file says.** `--print` emits no line the author did
  not write, and it emits in the source's facet — `.k` output carries no `~`
  (310_150).
- **Surface is what the program imports.** `glance` lists the entry file's
  own imports plus auto-pulled ancestors/descendants — never modules that
  only ride inside the env subtree (310_151). Filter by namespace coverage
  of the author's import decls, not by name-matching `std.compiler`.

The same discipline generalizes: anything the toolchain writes INTO the
program (injection, synthesized imports, canonical namespaces) must be
distinguishable from what the author wrote, because errors, canonical
source, and introspection all present the author's program back to them.
