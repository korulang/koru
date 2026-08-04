---
type: belief
id: frag-k-file-is-a-full-program
provenance: introduced with the KORU111 Rule 1 removal + 140_016 pin, during the .kz→.k corpus migration; contradicts the "contract file" model that 140_006 encoded
ts: 2026-07-17
---

# A `.k` file is a full program, not a contract-only surface

We believed a `.k` file was a **pub-only contract companion**: a public
interface sitting beside a `.kz`/`.kjs` implementation, holding only `~pub`
tor declarations. KORU111 Rule 1 encoded that belief — it rejected a private
tor in a `.k` as "dead syntax," on the reasoning that *no procs live in `.k`,
so nothing inside the file can call a private tor.*

That reasoning is false, and the belief flipped: **a `.k` is a full program.**
Tors implement as pure Koru right there in the file (subflow / immediate-impl,
not a host proc), and the file's own local flows call them — including private
ones. So a private tor in a `.k` is not dead; it is ordinary internal
vocabulary. Forcing it out to a `.kz`/`.kjs` companion "just because" is
backwards, and it is *why* so much of the corpus was needlessly `.kz`: pure-Koru
programs wearing the host extension only to satisfy a rule that shouldn't have
existed.

The ruling (Lars, 2026-07-17): **private tors are legal in `.k`.** Rule 1 is
removed. The "contract file" category dissolves — a `.k` is simply pure Koru;
the contract/implementation *split* remains an available pattern, not the
definition of the extension. Rule 2 (a `~pub` tor must not be re-declared in a
`.kz` when a `.k` companion exists — single source of truth for the public
surface) is untouched and still fires. Pinned by `140_016`.

Open question — the thing Rule 1 was quietly standing in for: **cross-module
private-tor visibility.** A private tor should not be *callable across a
module boundary*, but nothing enforces that yet (the long-open `110_002` TODO).
Rule 1 was accidentally covering a slice of it. `140_006` (the old Rule-1
negative) is marked TODO to be reworked into a genuine cross-module-visibility
test once that enforcement exists — its `input.kz` calls a private tor across
modules and *should* still fail, on visibility grounds, not on "private-in-`.k`".
