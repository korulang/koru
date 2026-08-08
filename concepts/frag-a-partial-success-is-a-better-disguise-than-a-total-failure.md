---
type: belief
id: frag-a-partial-success-is-a-better-disguise-than-a-total-failure
provenance: 690_269 — two wrong diagnoses survived because the value substitution worked while its declaration vanished
ts: 2026-08-08
---

# A partial success is a better disguise than a total failure (belief)

A feature that fails outright sends you to the code that should have run. A
feature where *half* the work lands sends you somewhere worse: to the half that
worked, looking for why the other half did not follow.

690_269 cost two wrong diagnoses to that shape. A value built from a template
inside an `if` arm emitted `value_0: __koru_tmpl_1` — correctly substituted —
and nothing declared that name. The first reading was "the lowering never
reaches a frozen body, so the raw template ships as text". Plausible, and false;
it was committed before the emitted output was read. The second was "the freeze
renders the arm to text and the declaration rides on an invocation that no
longer exists". Also plausible, also false, and it *located a real hole in the
JS emitter by accident* while being wrong about the store.

The truth was two independent defects sharing one symptom. The store wrote its
preamble to a TEMPORARY — `switch (@constCast(n).*) { .invocation => |*inv| }`
captures a copy — while `a.value` survived because args is a slice whose data is
shared even when the struct around it is not. And the JS emitter never emitted a
nested invocation's preamble at all, where the Zig emitter did.

**The tell, and it is worth training on: when part of a transformation lands and
part does not, the two halves probably travel by DIFFERENT ROUTES.** Value and
preamble looked like one payload on one object. They were a shared slice and a
copied field. Ask what each half is carried by before asking why one arrived.

The method that ended it, after reading failed twice: read the EMITTED OUTPUT on
both lanes and compare. Zig refused at compile time, JS threw at runtime, and
the difference between those two messages is what separated the store's bug from
the emitter's. Reasoning about which pass owns what produced two stories;
comparing artifacts produced the answer.

Related: [[frag-a-textual-substitution-over-source-needs-a-code-mask]] — same
file, same day, and also a case where a mechanism existed and was applied at one
site and not its sibling.
