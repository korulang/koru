---
type: belief
id: frag-command-position-is-strictly-post-file
provenance: koru-libs `stack` dogfood (2026-10-03) — `koruc app.k --build=dev
  stack manifest` ran a normal build; the command sat in the tail ignored.
  Fixed in main.zig, pinned 310_134. Evolved 2026-10-27: the "unmatched word
  still builds" carve-out measured as the same swallow — Q3 in
  challenges/018_FIX_QUEUE.md — and was closed, pinned 310_144.
ts: 2026-10-03
---

# Command position is strictly the arg after the input file (belief)

`koruc`'s command scan takes `args[input_file + 1]` as the command candidate,
unconditionally — whatever sits there wins the slot. A flag in that slot
(`koruc <file> --build=dev <cmd>`) is collected as `potential_command`,
matches no declared command after imports, and the real command drifts into
`command_trailing_args` where nothing ever reads it. The run proceeds as a
perfectly normal build. The invocation *looked* valid — file, flag, command,
all present — and silently did the wrong thing.

The rule this mints: **a declared command name stranded in the tail while the
command slot holds a flag is a refusal, not a no-op.** The check happens at
resolution time, when the full command surface is known — comptime declares,
shell/zig/koru.json commands, and the frontend verbs (`mint`, `help`,
`glance`, `at`). The refusal names the command and the correct order.

**Widened 2026-10-27**: the carve-out "an unmatched tail word that declares
nothing still builds" was itself the swallow — trailing words are never
forwarded to the program, so a `run`/`build`/`lib`/`bundle` typed after the
file built quietly and never ran, and any other undeclared word was dead
input with a clean exit 0. Now nothing that reaches resolution unclaimed
survives: a leading verb in the slot refuses with the corrected order, any
other undeclared word refuses as "not a command the file declares". Flags in
the slot stay flags; declared commands still win the slot first, so a program
that declares `run` keeps it.

Third member of a family: the step-graph swallow, the registry swallow, and
now the argv swallow — three places where a command-shaped invocation was
absorbed by a path that never saw it. The family's shared shape is a command
contract honored only on the exact spelling the implementer used.

Related: [[frag-command-dispatch-primes-comptime-registries]] (the backend
swallow — dispatch predates the registry pass),
[[frag-a-command-and-the-build-step-graph-are-disjoint-paths]] (the frontend
swallow — the step graph takes the command verb).
