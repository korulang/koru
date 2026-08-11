---
type: belief
id: frag-a-flagship-target-proves-nothing-about-the-ordinary-path
provenance: targeting bare wasm for a Vercel experiment — three hosted-platform assumptions in the emitted preamble, none of which the unikernel had ever exercised
ts: 2026-08-11
---

# A flagship target that travels a different route is not evidence about the ordinary path (belief)

Koru boots a unikernel. No operating system, no libc calls we did not put there,
a real HTTP server answering real requests on bare hardware. That achievement is
the strongest thing we can say about the language reaching hostile targets, and
it is exactly why it was able to hide a hole.

The unikernel does not build the way an ordinary Koru program builds. It is
compiled into a static library and linked by `kraft` against Unikraft's own
runtime, which supplies a libc. So the emitted program's *scaffolding* — the
allocator spine, the leak-check epilogue, the driver's copy of the finished
artifact — was never asked whether it could survive a machine with no libc and
no syscalls, because on that target it was never on the path.

Bare wasm asks. And the answer was that three separate one-line assumptions,
none of them written by any user, made the ordinary path refuse a target with no
operating system under it: an allocator that could not be *named* without a
malloc to bind to, an epilogue reaching for stderr and a process to exit, and an
artifact looked up under a name only hosted targets produce.

**The general claim: a success is evidence only about the code path it traversed.**
Reasoning from "we already run on the hardest target" to "the easy version of
that target must work" is reasoning about the destination when the variable is
the route. And the more impressive the flagship, the more confidently the
inference gets made — which inverts the usual intuition that a harder case
subsumes an easier one.

## Why this class of hole is invisible rather than merely unfound

Each assumption was correct on every target anyone had run. That is not a
coincidence to note in passing; it is the mechanism. An assumption that holds
everywhere it has been evaluated produces no signal at all — not a warning, not
a slow path, not a comment. It reads as an absence of a problem.

And the failure surfaces in the worst possible register: the compile errors
quoted lines in the *emitted* program, so they name Zig's `std.posix` and
`std.Thread` at coordinates in a file the author never opened. A user meeting
this would reasonably conclude their target was unsupported, because nothing in
the diagnostic distinguishes "the language cannot do this" from "three lines of
compiler-authored scaffolding assume otherwise."

The third one is worse than the first two and worth separating: the build
**succeeded**, and the driver reported failure because it looked for the artifact
under a name only non-wasm targets use. A green result announcing itself as red
is not a lesser failure than a red one — nothing downstream can tell them apart,
so the working capability stays unbelieved.

## The corrective worth keeping

Before treating a target as unsupported, establish which route the evidence for
"supported" travelled. The question is not *has Koru reached a bare machine* —
it has — but *did it reach one through the code this build will execute*. Related
to [[frag-a-second-target-is-what-forces-a-language-to-name-its-own-vocabulary]]:
there, a second target made the language define its expression surface; here, a
second *bare* target made it define its runtime scaffolding. The instrument is
the same in both cases — an unlike-enough consumer — and in both cases what it
exposed was something the existing target had answered by default rather than by
design.

## The mechanism, sharpened by measurement (2026-08-11, later the same day)

The route account above is right about the conclusion and wrong about the
machinery, and the difference matters because it changes what to check next.

The unikernel **does** carry the emitted preamble. `kraft` links
`libkoruapp.a`, which is `wrapper.zig` compiling `output_emitted.zig` — the same
scaffolding, allocator spine included, present in the object. It was never
*compiled* only because Zig does not analyze a function body nothing reaches, and
the one program on that target never asked for a byte. So the flagship did not
take a different route around the scaffolding; it walked past it without ever
looking inside.

That is a stronger form of the same lesson. A route you avoid can at least be
noticed as unvisited. A function that is present, shipped, and simply never
called produces an artifact where the dead code is indistinguishable from live
code by inspection — and every count of "does the unikernel build?" comes back
yes. Confirmed by reverting the fix: an allocating program fails to compile for
`x86_64-freestanding` where a non-allocating one succeeds, from the same
scaffolding text.

Also corrected: "Unikraft's own runtime, which supplies a libc." It supplies the
*symbols* — `nm -g` over the 0.21.0 build shows `T malloc`, `T free`,
`T posix_memalign` — but our compile sets `link_libc = false`, which is exactly
why `std.heap.c_allocator` could not be NAMED while `extern fn posix_memalign`
links fine. Symbols in the image and a libc known to the compiler are different
facts, and conflating them is what made the allocator look unfixable.

Pinned by koru `310_122`; the demonstration now allocates
(`examples/unikraft-net/serve.kz`), so the scaffolding is reached rather than
merely shipped.

## What would correct this belief

Finding that the emitted preamble is genuinely absent from the unikernel image —
rather than present-but-unanalyzed, which is what was measured — would make this
a story about an untested target rather than a misleading one, and the lesson
would collapse to ordinary "we never tried wasm."

It would also be corrected by evidence that these three assumptions were known
and deliberately deferred, rather than never asked. Nothing in the tree said so:
the comments at each site explain *why libc's malloc* over a debug allocator,
and *why* the leak count is absolute, but neither entertains a target where the
named thing does not exist.
