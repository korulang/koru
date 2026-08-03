---
type: belief
id: frag-a-fix-installed-at-the-site-that-needed-it
provenance: the last two reds of the 115 mirror wall, 115_004 and 115_036; both were correct code that had been installed one level too low, and both had been green for months from the entry file
ts: 2026-08-02
---

# A fix installed at the site that needed it is a fix that only works there (belief)

Two of the last three module-mirror reds were not missing code. The code
existed, was correct, and had been exercised for months. It had simply been
written into the one place that first needed it, and the thing that decides
whether that place is reached had nothing to do with the property being
protected.

**The `for`-capture uniquifier.** The `~for` template renders a hardcoded
`for (..) |__koru_item|`, so two instances in one Zig function collide. The
emitter renames each instance's capture — inside ONE branch of a three-exit
function, the branch taken when the invoked event declares effect arms.
Which exit a body takes is decided by inline eligibility. So the same nested-`for`
program was safe compiled from the entry file and a Zig shadowing error compiled
from inside a module: not a module bug at all, a *reachability* bug that a module
happened to expose. The property — "this rendered body owns its capture name" —
belongs to the BODY, so it belongs at the function's entry, before any branch.

**The scope registry.** `register` emits its descriptor and dispatcher beside
the events they name, which is the only place they can be — Zig gives a sibling
struct no path to the entry struct. The comptime scan that discovers them read
`root.main_module` and nothing else. A scope registered in a library was
therefore invisible, and invisible *quietly*: the program compiled, ran, and
took its `| scope-not-found` arm. A well-formed answer built on an empty
registry.

## The tell, and it is available before the bug

Both fixes read as complete because each site's own reasoning is sound. What
gives them away is a mismatch of *quantifiers*: the property is universal ("every
rendered body", "every registry in the program") and the installation is
existential ("this branch", "this namespace"). When a comment justifies a fix by
describing the case that motivated it, ask what else is in the universal — the
answer is usually "one other exit" or "one other container", and it is usually
already in the tree.

Concretely, for anything that guards a name or discovers a declaration:

- **Guards go at the entry**, not in the branch where the collision was first
  seen. A three-exit function with the guard in one exit is two latent bugs.
- **Discovery walks name a set, not a place.** `root.main_module` is a place;
  "every namespace the emitter writes" is the set. If the walk hardcodes one
  container, the second container is a matter of time.

## Why this class survives so long

Because the entry file collapses the distinction. Every one of these was green
for months, exercised constantly, by programs that could not tell the difference.
That is the same collapse
[[frag-transform-module-exposure-is-not-one-fault]] identifies for names — and it
is now clear the collapse hides *reachability* too, not only naming. The 115 wall
finds both, and cannot tell them apart until each red is chased to its cause.

## The one that is not this

`115_020` stayed red and is not a module finding at all: its original, `690_069`,
is red for the reserved row ordinal. A mirror whose original is red says nothing
about the boundary. That check is cheap and belongs before any diagnosis on this
wall.

## The sibling: correctness held by a PLACEMENT COINCIDENCE (2026-08-03, 115_043)

The cases above are code installed one level too low. This is the inverse and it
is quieter: code that was never installed anywhere, and worked because of where
the surrounding thing happened to land.

A store's variable is declared in its own module's namespace. A sweep over that
store emits `__koru_store_items` BARE. That is wrong everywhere and correct
nowhere — but with no capture the sweep's loop is lifted into a
`__store_sweeprun_*` event that is PLACED IN THE STORE'S OWN NAMESPACE, so the
bare name resolves. Add a capture and the loop must stay inline at the sweep
site to keep the captured value in lexical scope; inline means the CALLER's
namespace, and the same bare name stops resolving.

The emitted statement indicts itself:

    // inside koru_app.koru_lib.koru_systems
    for (0..__koru_store_items.len) |__koru_si| {                        // BARE
        koru_app.koru_lib.koru_world.__store_sweepbody_items_L8_event...  // QUALIFIED
    }

Two references, one statement, both naming things that live in `koru_world`,
and only one qualified. The emitter already knew the home — it wrote the path
for the body — so nothing was undiscoverable. One of the two spellings was
simply never taught.

What this adds to the tell above: the existing rule says to ask what else is in
the universal when a fix sits in one exit. **Also ask what makes the CURRENT
placement correct.** If the answer is "it happens to be emitted next to the
thing it names", that is not correctness, it is a coincidence with a lifetime —
and it ends at the first feature that moves the code. Here the feature was
capture, which is orthogonal to naming and had no reason to be suspected.

A bare symbol is a claim about the emitting namespace. When the same emitter
qualifies its sibling reference three tokens later, the bare one is not a
shorter spelling of the same claim — it is an unexamined one.

Each half is green alone: same-module capture runs, cross-module without
capture runs. Only the combination fails, which is why neither half's tests
ever had reason to look.

## The third form: a MANUAL ENUMERATION of a set that just grew (2026-08-03)

Adding one field to `ast.DestructureField` took four attempts to land, and the
two misses were the same shape as everything above — code that must change,
sitting somewhere nobody was looking.

The reflective paths were free. `ast_json`'s reader walks `@typeInfo` fields,
so it picked the new field up with no edit at all, and `program_ast.zig` is a
bare `pub const DestructureField = ast.DestructureField` alias. Every path that
DESCRIBES the type rather than enumerating it cost nothing.

The two that bit both enumerate by hand:

- `ast_serializer.zig`'s `serializeDestructure` writes `.name`, `.type_text`,
  `.sub` — a new field is silently absent from the emitted literal.
- `ast.copyDestructure` constructs the copy field-by-field. A clone that omits
  a field does not fail; it produces a value that is correct everywhere except
  the property you just added, and the loss surfaces arbitrarily far away. Here
  the parser was demonstrably right (`--ast-canon` showed the annotations) and
  the consumer saw an empty list, with a clone in between.

**A manual field enumeration is a place new fields go to die**, and the tell is
the same one this belief already gives for guards and discovery walks: it names
a PLACE (these three fields) where the type names a SET. Reflection over
`@typeInfo` is not merely less code — it cannot fall out of step, which is the
entire failure mode.

Practical consequence, cheap: when adding a field to an AST type, grep for an
existing field's name rather than the type's. `grep '\.type_text'` finds every
hand-written enumeration in one shot; `grep DestructureField` finds the
declarations and misses all of them.

It also caught a scope estimate. I told Lars four files, having checked the
serializer and stopped; the deserializer and the clone were both still ahead.
Reading one direction of a round-trip and calling it the scope is its own
instance of this belief.
