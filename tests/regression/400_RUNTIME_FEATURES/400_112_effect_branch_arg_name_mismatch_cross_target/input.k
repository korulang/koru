// FRONTIER (pinned RED on the JS target): effect-branch dispatch where the
// dispatch arg's name DIFFERS from the target event's field name.
//
// The effect branch binds `! tick i`, dispatched as `onTick(i)`. But onTick's
// field is named `slot`, so this is a POSITIONAL arg whose name (`i`) does not
// match the field (`slot`). The Zig path resolves the arg by position and
// passes. The JS inline-plain-handler path (src/js_emitter.zig:421-429,
// `emitInlinePlainHandler`) resolves dispatch args ONLY by field-name match:
//
//     const arg_val = argValueByName(inv.args, field.name) orelse
//         return JsEmitError.UnsupportedConstruct;   // <- aborts here
//
// `argValueByName` looks up `arg.name == field.name`; the punned arg's name is
// the binding `i`, the field is `slot`, no match → UnsupportedConstruct →
// the backend dies via Abort trap (signal 6) when emitting JS.
//
// DIVERGENCE OBSERVED:
//   Zig  : compiles + runs, prints `hits=1`
//   JS   : koruc --lang=js panics — `js_emitter.emit failed: UnsupportedConstruct`
//          at js_emitter.zig:424 (emitInlinePlainHandler), no output_emitted.js
//
// FIX SHAPE: the JS inline-plain-handler must resolve dispatch args
// POSITIONALLY (zip event.input.fields with inv.args by index) when there is
// no name match — matching the Zig path — instead of requiring field-name
// equality. Until then this test stays RED on JS and GREEN on Zig.
~pub event ticker { n: u64 }
! tick u64
~pub event onTick { slot: u64 }
~pub event report {}

~ticker(n: 1)
! tick i |> onTick(i)
~report()
