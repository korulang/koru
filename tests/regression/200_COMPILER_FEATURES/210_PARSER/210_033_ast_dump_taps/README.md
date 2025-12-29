# Test 631: AST Dump with Event Taps

## Purpose

Documents how to use the `dump_ast` event with taps to observe the compiler pipeline and debug transformations.

## Key Concepts

### Event Taps for Observation
```koru
~* compiler.coordinate.optimize -> continued
|> dump_ast(ctx: ctx, stage: "post-optimization")
```

Taps let you observe events without modifying the main flow. The `dump_ast` event is called whenever the tapped event completes.

### Void Events
`dump_ast` is a void event - it has no branches, only side effects (printing to stderr). This makes it perfect for logging/debugging:

```koru
~pub event dump_ast { ctx: CompilerContext, stage: []const u8 }
// No branches! Just prints and returns void
```

### Pipeline Stages

1. **post-frontend**: AST after parsing + comptime evaluation
   - All source-level constructs present
   - EventDecl, ProcDecl, Flow, SubflowImpl, etc.

2. **post-analysis**: AST after validation passes
   - Same structure as frontend
   - Errors would have been reported

3. **post-optimization**: AST after IR transformations
   - **IR nodes appear here!**
   - NativeLoop replaces SubflowImpl with label loops
   - FusedEvent replaces pure event chains
   - InlinedEvent replaces small events

4. **pre-emission**: Final AST before code generation
   - Same as post-optimization
   - Ready to emit Zig code

## What to Look For

In the dump output at **post-optimization**, you should see:
- Item count stays the same (IR nodes replace source nodes)
- Passes completed increases (each stage increments)
- When full JSON serialization is enabled, you'll see:
  - `"native_loop"` entries where SubflowImpl used to be
  - Loop metadata (variable, start, end, body)
  - Optimized_from field showing original event

## Using This Pattern

To debug your own optimizations:

1. Add taps at relevant stages:
```koru
~* compiler.coordinate.your_pass -> continued
|> dump_ast(ctx: ctx, stage: "post-your-pass")
```

2. Run the compiler and check stderr for AST dumps

3. Compare before/after to verify transformations

## Future Enhancement

Once ast_serializer integration is complete, dump_ast will output full JSON showing the complete AST structure including IR node details.
