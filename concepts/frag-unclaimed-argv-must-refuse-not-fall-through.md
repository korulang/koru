---
type: belief
id: frag-unclaimed-argv-must-refuse-not-fall-through
provenance: quirk-hunt second run, 2026-10-11 — `koruc <file> zzzzzz`, `koruc
  <file> run`, `koruc <file> out.zig`, and `koruc --depp-check <file>` all
  byte-identical to a clean build, exit 0
ts: 2026-10-11
---

# Any argv token that reaches no handler must refuse — falling through to a successful build is the lie (belief)

`main` collects the command-position word into `command_candidate` and
comments the rest away: "Silently ignore other non-flag args — might be
command name or command args". Unknown flags land in `compiler_config` as
opaque pass-throughs. Both buckets share one failure shape: a token the user
intended as *meaningful* produces the exact output of its absence — the same
✓ lines, the same executable, the same exit 0. Nothing downstream can tell
"the command ran" from "the command was never heard".

This is the general case of three recorded instances:

- `koruc deps <module>` used to discard the module in silence — fixed with a
  teaching refusal, and the refusal's own comment names the defect: the
  discarded argument "printed a clean toolchain report and exited 0, which
  reads as your project's dependencies are fine".
- A `[comptime|command]` floated beside `std/build:step`s was swallowed by
  the frontend's early return (frag-a-command-and-the-build-step-graph…).
- `-O` fell into the flag bucket as a dead flag while its argument became a
  stray positional (frag-passthrough-flags-swallow-conventional-spellings).

Each instance got cured at its own site; the *position* stayed open. The
ruling that generalises all three: argv is a contract surface. A token in
the command position either names a dispatchable command or it is a user
error, and a user error that prints success is the worst diagnostic there
is — it teaches the wrong command worked. Refuse it, name it, and when the
token looks like a real spelling on the wrong side of the file (`<file> run`,
`deps <module>`), quote the line the user meant.

The one exception that keeps the rule honest is the provider channel:
`--name=value` is a program-defined atom by design, not a claim on the
toolchain. Unclaimed *bare* flags and unclaimed *words* have no such charter.
