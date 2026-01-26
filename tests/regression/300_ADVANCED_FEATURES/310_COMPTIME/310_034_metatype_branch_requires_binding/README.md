# Metatype Branch Requires Binding

## Status: TODO

Currently the code compiles and runs - the emitter silently accepts branches
without bindings. Validation needs to be added.

## Expected Behavior

Metatype branches (like `Transition`) should require a binding:
- `| Transition t |>` - valid (captures transition data)
- `| Transition _ |>` - valid (discards transition data)
- `| Transition |>` - INVALID (missing binding)

## Why This Isn't Caught

The parser doesn't know about metatypes - it just sees valid branch syntax.
The shape checker validates bindings against event definitions, but metatype
branches are injected by the emitter during tap expansion, bypassing shape
checking entirely.

## Fix Required

The emitter needs to validate that metatype branches have proper bindings
when it injects them during tap processing.
