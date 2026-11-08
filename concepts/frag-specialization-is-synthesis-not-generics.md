---
type: belief
id: frag-specialization-is-synthesis-not-generics
provenance: AoC day22p2 design session — `Heap_i64` vs `Heap[i64]` forced the question; gemv-retarget spike is the existence proof
ts: 2026-11-07
---

# Specialization is synthesis, not generics — `X[i64]` names a synthesized type, never an application

Koru does not have — and will not grow — a generics mechanism in the
Rust/C++/Go sense. That mechanism exists in those languages because their
compile time cannot evaluate code generally, so designers carved out a
checkable subset: quantify over types, monomorphize, done. It is an
admission that full metaprogramming was unavailable — a safe imitation of
what comptime could have been.

Koru's comptime transforms are the unrestricted version. `gemv.kernel[*]`
with `[T:f32;I:1024;J:512]` does not apply a generic function — a `~proc`
reads the bracket tail as an opaque parameter string and *writes the
specialized program*: typed storage, unrolled kernel, differential oracle,
report fn. Four monomorphs, bitwise-identical, verified 2026-10-23
(`koru-benchmarks/spikes/gemv-retarget/generic/`). Bracket params are
parameters on a NAME; whatever they name is materialized, never applied.

The `X_i64` wart (`List_i64`, `Set_i64`, `Map_i64_i64`) is the flat
namespace encoding of "instantiation is just a name." It is honest about
today's substrate and dishonest about what the type IS — a synthesized
specialization, not a primitive called List-underscore-i64.

**The ruling direction:** `Heap[i64]`-style spelling is the target — a
type name carrying an opaque parameter tail, resolved by synthesis
machinery, never by type-system application. The open question is what
materializes the bracketed name, in increasing machinery:

1. **Alias table** — `Heap[i64]` resolves to an already-declared concrete
   type. Every usable parameterization needs a registered decl; brackets
   become pure spelling. Honest, manual.
2. **Type-family template + substitution** — the body is written once
   with the element type as a bracket param; `Heap[i64]` triggers
   AST-level substitution producing a concrete decl. Generics *in
   effect*, implemented as name-level synthesis — the `[*]` ruling
   lifted from tor-invocation to type-name. The Koru-native answer.
3. **`~proc` transform per family** — the GEMV pattern verbatim: host
   proc parses `[i64]`, emits the whole module. Most powerful, most
   machinery, hardest to debug.

Probe evidence (2026-11-07, this tree): `List[i64]<list>` in type
position PARSES — the grammar already accepts `Name[params]` — but the
bracket content is dropped at backend and `<list>` resolves as a
module-local phantom (`gentest:List<gentest:list>`), not
`std.list:List_i64`. So the syntax half exists; the semantics is the
whole gap. Whatever wins, the first work item is deciding what bracket
params in type position are ALLOWED to mean — under this ruling, never
type-system application, always synthesis parameters.

**Landed 2026-11-07 (direction 1, name-level only):** `Name[params]` in
type position now canonicalizes to the underscore-joined synthesized
decl — `Heap[i64]`→`Heap_i64`, `Map[string,i64]`→`Map_string_i64` — via
`rewriteBracketParams` in canonicalize_names, with the parser retaining
`Ident[params]` in `field.type` (splitTrailingAnnotationsOwned spares
brackets whose content is a type-param list; `i64[note]`/`Source[HTML]`/
`u64[\d+]` annotations still peel). Conservative edge: a bare-identifier
param (`Heap[Node]`) is indistinguishable from an annotation atom and
stays an annotation — params must be base-type keywords, prefixed,
qualified (`mod:Type`), or nested parameterized spellings. Pin:
660_039_bracket_type_spelling.

**Checked abstraction is buildable, not traded away (ruling
2026-11-07, Lars):** an earlier draft of this note framed "generics
buy checked abstraction — the template type-checks once, generically"
as a trade Koru accepted. That framing was wrong: nothing in the
comptime machinery prevents checking synthesis output or templates —
the pipeline is fully programmable and transform output already goes
through the same checker. If "check the template once, parametrically"
is impossible today it is an unimplemented capability and a core-design
gap to fix, not an inherent cost of choosing synthesis. Option 2's
template lives in Koru source and can be checked by the same pipeline;
the missing piece is machinery, not permission.

**The full ruling (2026-11-07, Lars):** compile-time transforms are part
of the user-programmable pipeline — the user program can disable them.
They are not privileged compiler machinery. Generics therefore do not
belong at the language level at all: they belong in user space, at the
module level, and not even there as a first-class concept — because the
purpose of generics is specialization, not generics. `Heap[i64]` is the
spelling; whatever materializes it lives in `std/heap`'s module space,
not in the typechecker.

**Open questions:** does the phantom `<state>` suffix compose with
bracketed names (`Heap[i64]<heap>` — state stays family-level like
`<list>` today)? Does option 2's substitution reuse the `[*]` bracket
parser or need its own? Is there a migration path off `X_i64` names or
do they remain as the concrete decls the aliases point at?
