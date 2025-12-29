# Optimizations Specification

> **Status**: ✅ Phase 1-3 implemented, ⏭️ Phase 4-5 planned

📚 **[Back to Main Spec Index](../../../SPEC.md)**

## Optional Branches

### What Are Optional Branches?

Optional branches are event outputs that handlers may choose to ignore without error. They enable:
- **API Evolution**: Add new branches without breaking existing code
- **Zero-Cost Abstractions**: Rich events where you only pay for what you use
- **Dead Code Elimination**: Compiler removes unused branch code (planned)

### Syntax

Mark branches as optional with the `?` prefix:

```koru
~event process { value: u32 }
| success { result: u32 }        // REQUIRED
| ?warning { msg: []const u8 }   // OPTIONAL
| ?debug { details: []const u8 } // OPTIONAL
```

### Semantics

**Required branches** must be handled:
```koru
~process(value: 10)
| success |> handle_success()    // ✅ Must handle
| warning |> handle_warning()    // ❌ Optional - not required
```

**Optional branches** can be omitted:
```koru
~process(value: 10)
| success |> handle_success()    // ✅ Only required branch handled
// warning and debug are optional - OK to skip!
```

### Code Generation

When not all branches are handled, the compiler generates:
```zig
switch (result) {
    .success => { /* handler code */ },
    else => unreachable,  // Only if some branches unhandled
}
```

When ALL branches are handled, no `else` clause (Zig requires this).

### Design Intent

Optional branches express that a branch is **supplementary**, not **core** to the event's contract.

**The event designer decides** what's optional - not the handler author. This is intentional:
- Event APIs can evolve with new diagnostics/debugging/profiling branches
- Existing handlers don't break
- New handlers can opt-in to richer features

### Examples

See working tests:
- [918_optional_branches](918_optional_branches/) - Basic functionality (✅ implemented)
- [919_dead_code_elimination](919_dead_code_elimination/) - Unused branch elimination (⏭️ Phase 4)
- [920_handler_caching](920_handler_caching/) - Handler specialization (⏭️ Phase 5)

### Implementation Phases

- **Phase 1**: ✅ Parser & AST (line 472 in `src/ast.zig`)
- **Phase 2**: ✅ Shape checker (lines 114-116 in `src/shape_checker.zig`)
- **Phase 3**: ✅ Code generation (lines 2323-2328 in `koru_std/compiler_bootstrap.kz`)
- **Phase 4**: ⏭️ Dead code elimination (not yet implemented)
- **Phase 5**: ⏭️ Handler caching & specialization (not yet implemented)

### Related Specifications

- [Control Flow - Continuations](../100_CONTROL_FLOW/SPEC.md#continuations) - How branches are handled
- [Validation - Branch Coverage](../400_VALIDATION/SPEC.md#branch-coverage) - Coverage checking rules
- [Core Language - Events](../000_CORE_LANGUAGE/SPEC.md#event-declaration) - Event syntax basics

### Use Cases

**Rich Parsing API**:
```koru
~event parse { input: []const u8 }
| success { ast: AST }
| error { msg: []const u8 }
| ?warning { msg: []const u8 }       // Optional diagnostics
| ?perf_stats { duration_ns: u64 }   // Optional profiling

// Production: ignore diagnostics
~parse(input: source)
| success |> compile()
| error |> report()

// Debug: use all branches
~parse(input: source)
| success |> compile()
| error |> report()
| warning w |> log_warning(w.msg)
| perf_stats p |> record_stats(p.duration_ns)
```

---

**Last Updated**: 2025-10-05
**Verified Against**: Tests 918-920
