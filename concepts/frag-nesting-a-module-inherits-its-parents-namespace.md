---
type: belief
id: frag-nesting-a-module-inherits-its-parents-namespace
provenance: A package index and its sibling submodule both wrote `const std = @import("std")`. Emitted as `koru_mylib` containing `koru_mylib.koru_helper`, the inner reference became `error: ambiguous reference`. Zig containers do not shadow. Found 2026-08-08; fixed and pinned as 110_030
ts: 2026-08-08
---

# Nesting a module inside another makes it inherit a namespace it never asked for

Koru emits a submodule inside its parent's Zig struct — `mylib.helper` becomes
`koru_mylib.koru_helper` — because the nesting mirrors the module path and makes
call sites read the way the import does. It is the obvious lowering. It also
quietly hands the inner module every name the outer one declares, and **Zig
containers do not shadow**: a nested declaration of a name an enclosing container
also declares is not an override, it is `error: ambiguous reference` at the first
use.

Which means the most ordinary thing a Koru file can contain — `const std =
@import("std")`, written once per file by every file that touches the host
language — made a package that had both an index and a sibling uncompilable.
Not a rare shape. The default one.

The general point: **a lowering that nests scopes has adopted the host's scoping
rules for the whole surface above it**, including rules the source language never
had. Koru modules are files, and two files declaring the same local name is not a
conflict in Koru; the conflict is manufactured entirely by the choice to nest.
Any lowering that maps a flat namespace onto a nested one owes an answer for what
happens when the same name appears at two levels, and "the inner one wins" is
only available if the host says so.

The fix here is deliberately narrow: an inner byte-identical
`const <name> = <path>;` is dropped and the reference resolves outward to the
same thing, where `<path>` is a pure navigation expression — `@import("std")`,
`std.posix`, `@import("std").mem`. A `var` is distinct storage; a `const` with a
call, an operator or a literal in it can mean something different inside. So the
general case is still refused, loudly, which is correct until the emitter mangles
per-module names. **Naming what a fix does NOT cover is part of the fix**; the
alternative is a reader assuming the shadowing problem is solved and meeting it
again at a `var`.

The boundary moved once already, and how it moved is the lesson. The first cut
allowed only `@import(...)` — which felt like the principled line, since an
import alias is obviously the same thing everywhere. Orisha's pump answered
within the hour with `const posix = std.posix;`, a second-order alias that is
every bit as safe and did not match. **A rule drawn around the one example that
provoked it fits that example, not the class.** The class here is "binds a name
to a namespace by navigation", and `@import` is one member of it, not its
definition. The head of such a path resolving differently inside is the only way
the widening could lie, and it cannot: that needs the inner module to redeclare
the head, and a redeclaration that is not byte-identical is never dropped.

Getting the boundary wrong the first time is instructive. The first attempt let
any identical `const` be dropped, which also matched a whole proc body reaching
the emitter as one host line — two identical `const cloned = …` statements in a
stdlib body, second one deleted, and the error landed on the *use* of a name
whose declaration had silently evaporated. A suppression rule is only as safe as
its narrowest reading of "the same thing".

Related: [[frag-a-dedup-key-must-be-an-identity-not-a-spelling]] — the sibling
defect found in the same hour; that one made a module arrive twice, this one made
two genuinely different modules collide. Both surfaced as `duplicate struct
member name 'std'`, which is why they read as one bug for a night.
