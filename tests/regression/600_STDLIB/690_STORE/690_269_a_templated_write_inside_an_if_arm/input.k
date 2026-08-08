// PINS A HOLE, RED BY DESIGN: a templated write inside an `if` arm emits its
// value but loses the buffer that value names.
//
// 690_268's write sits directly in a rule arm and works. This one differs ONLY
// by the `if`. The lowering DOES fire here — the emitted write reads
// `value_0: __koru_tmpl_1`, correctly substituted — but nothing declares
// `__koru_tmpl_1`, so JS throws ReferenceError and Zig refuses the call.
//
// ⚠ THE FIRST VERSION OF THIS HEADER HAD THE MECHANISM WRONG. It said the
// lowering never reached a frozen body and the raw template shipped as text.
// That reads plausibly and is false: the value is substituted, and what is
// lost is the DECLARATION. Corrected after reading the emitted output on both
// lanes rather than reasoning from where the code sits.
//
// THE CAUSE: a built value's buffer is declared in the invocation's preamble,
// which is how it outlives the copy the write makes. `if`/`for` are template
// procs that FREEZE their rendered arm into text (the freeze 690_074 pins), so
// the stored invocation becomes rendered text and the preamble riding on it
// has nothing left to ride. The write survives the freeze because it is part
// of the text; its declaration does not, because it was never in the text.
//
// THE FIX IS GENERAL, AND BELONGS IN THE FREEZE, NOT HERE. A preamble is how
// ANY transform attaches a statement to a value — six stdlib modules produce
// one (control, constructor, field, list, kernel, store). It rides on the
// invocation, and `template_processor.zig:1057` freezes a rendered arm into
// text without carrying it, so every one of them loses its statement inside an
// `if`/`for` arm. This test is the instance that exposed it, not the extent of
// it. Making the continuation-to-text render emit a node's preamble before its
// rendered call fixes all six at once.
//
// The floor, correct on its own and not waiting for that: REFUSE a `{{ … }}`
// write the lowering cannot place, rather than emitting a name nothing
// declares.
//
// Found by the DOM gauntlet's conformance check, not by this suite — the
// second time a check outside the suite has caught a text-substitution defect
// this suite could not see.
import std/io
import std/store

std/store:new(flag) { on: 1[i64] }

std/store:new(rows, capacity: 4) { label: char[40] }

std/store:insert(rows) { label: "pony" }
    | row _ |> _
    | full |> _

std/store:rule(rows)
! row e |> if(flag.on == 1)
    | then |> std/store:stored { e.label: "{{ e.label:s }} !!!" } |> std/io:print.ln("{{ e.label:s }}")
    | else |> _
