// MIRROR of 130_006: a `std/vendor:bindings` declaration — the pin AND the import
// redirect it carries — relocated into an imported module.
//
// Two things have to hold at once here, and each was broken when this was written.
// The declaration must PARSE without a module resolver, which an imported
// module's parse can lack; and it must EMIT NOTHING, because a transform that
// erases itself inside a module previously survived into the runtime as a call to
// a compile-time-only handler.
//
// The pin is live: touch a byte under `vendored/` and this stops compiling.
import app/lib

app/lib:run()
