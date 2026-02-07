# AST Rewrite Workdoc

**Created:** 2026-02-07
**Status:** Planning
**Baseline:** 479/575 tests passing (83.3%). Never regress.
**Files:** Primary target is `src/ast.zig`. Blast radius: 26 files, ~115 occurrences of `subflow_impl`.

---

## Problem Statement

The AST design leaks implementation details into every consumer. The core issue: `Flow` and `SubflowImpl` are separate `Item` variants, forcing every transform, checker, emitter, and optimizer to handle both cases. This creates:

1. **Boilerplate in every transform** (~20 lines of unwrap/re-wrap per transform)
2. **Bugs when one variant is missed** (the `TransformDidNotReplace` class of errors)
3. **Fragile library code** (`ast_functional.replaceFlowRecursive` has to handle both)
4. **Leaky abstractions in .kz transforms** (user-authored transforms must know about `.subflow_impl`)

The motto is "coding is compiler coding" — AST issues compound into everything.

---

## Current AST Structure (ast.zig)

### Item enum (line 207) — 15 variants

**Source-level (parser):**
- `module_decl` — Module boundary with nested items
- `event_decl` — Event type declaration (input shape + output branches)
- `proc_decl` — Proc implementation body
- `flow` — Invocation + continuations (the core execution unit)
- `subflow_impl` — A flow wrapped with "which event does this implement"
- `event_tap` — Before/after observation hooks
- `label_decl` — Named continuation points
- `import_decl` — Module imports
- `host_line` — Raw Zig code lines
- `host_type_decl` — Zig type declarations
- `parse_error` — Lenient parse error placeholder

**IR nodes (optimizer):**
- `native_loop` — Recursive events optimized to for/while
- `fused_event` — Pure event chains fused into single handler
- `inlined_event` — Small events inlined at callsite
- `inline_code` — Template-generated verbatim code

### Flow (line 456)
```
invocation: Invocation
continuations: []const Continuation
annotations: []const []const u8
pre_label: ?[]const u8
post_label: ?[]const u8
super_shape: ?SuperShape
inline_body: ?[]const u8        // Raw Zig string — no type safety
preamble_code: ?[]const u8      // Raw Zig string — no type safety
is_pure: bool
is_transitively_pure: bool
location: SourceLocation
module: []const u8
```

### SubflowImpl (line 561)
```
event_path: DottedPath           // Which event this implements
body: SubflowBody                // Either a Flow or an immediate BranchConstructor
is_impl: bool                    // ~impl vs ~handler =
location: SourceLocation
module: []const u8
```

### SubflowBody (line 577)
```
flow: Flow                       // Full flow with invocation and continuations
immediate: BranchConstructor     // Immediate branch return (constants, defaults)
```

---

## Issue 1: Flow/SubflowImpl Duality

**Every consumer must handle both.** The pattern appears everywhere:

```zig
// This pattern appears in 26 files, ~115 times
if (item.* == .flow) {
    // handle flow
} else if (item.* == .subflow_impl and item.subflow_impl.body == .flow) {
    // handle the flow inside subflow_impl
}
```

**In .kz transforms** (control.kz, orisha/index.kz, etc.):
```zig
const flow = if (item.* == .flow)
    &item.flow
else if (item.* == .subflow_impl and item.subflow_impl.body == .flow)
    &item.subflow_impl.body.flow
else
    return .{ .transformed = .{ .program = program } };
```

**In ast_functional.zig** (replaceFlowRecursive, line 224-252):
The library function handles both cases AND auto-wraps if the caller passes a bare flow. But transforms ALSO manually wrap. Same logic in two places.

### Proposed Fix: Merge SubflowImpl into Flow

Add optional fields to `Flow`:
```zig
pub const Flow = struct {
    invocation: Invocation,
    continuations: []const Continuation,
    // ... existing fields ...

    // NEW: Subflow implementation context (null for top-level flows)
    impl_of: ?DottedPath = null,  // Which event this flow implements (null = top-level)
    is_impl: bool = false,        // true for ~impl, false for ~handler =

    // Helper for readability at callsites
    pub fn isImpl(self: *const Flow) bool {
        return self.impl_of != null;
    }
};
```

**Naming decision:** `impl_of` over `impl_event_path` — shorter at callsites, reads naturally: `if (flow.impl_of) |event_path| { ... }`.

The `SubflowBody.immediate` case (branch constructor without a flow) becomes a separate Item variant — it's not really a flow anyway:
```zig
pub const Item = union(enum) {
    // ...
    flow: Flow,              // Unified: both top-level and subflow impl
    immediate_impl: struct { // Was SubflowBody.immediate
        event_path: DottedPath,
        value: BranchConstructor,
        annotations: []const []const u8 = &[_][]const u8{},  // Preserve any impl annotations
        is_impl: bool = false,
        location: SourceLocation,
        module: []const u8,
    },
    // subflow_impl: REMOVED
};
```

**Note on `immediate_impl`:** Must carry the same metadata fields as today's `SubflowImpl` (annotations, is_impl, location, module). Any pass that currently assumes "all impls are subflow_impl wrapping a flow" must be checked — `immediate_impl` must not silently bypass shape checking, emission, or serialization.

**Blast radius:** 26 files. Mostly mechanical removal of `else if (item.* == .subflow_impl)` branches. The parser changes to produce `Flow` with `impl_of` set instead of wrapping in `SubflowImpl`.

**Safety net:** Add a temporary assert in `ast_serializer.zig` to catch unexpected `Flow` with null `impl_of` in contexts that must be impls. Remove after the migration is stable.

**Files affected (by occurrence count):**
- `visitor_emitter.zig` (14) — emission logic
- `emitter_helpers.zig` (13) — emission helpers
- `ast_functional.zig` (11) — AST manipulation library
- `parser.zig` (10) — AST construction
- `shape_checker.zig` (9) — shape validation
- `resolve_abstract_impl.zig` (5) — abstract event resolution
- `ast_serializer.zig` (5) — serialization
- `transform_pass_runner.zig` (5) — transform execution
- `auto_discharge_inserter.zig` (4) — phantom obligation insertion
- `tap_transformer.zig` (2) — tap transformation
- + 16 more files with 1-4 occurrences each

---

## Issue 2: inline_body / preamble_code as Raw Strings

`Flow.inline_body` and `Flow.preamble_code` are `?[]const u8` — raw Zig code strings. Problems:

- **No scope checking** — referencing `req` in inline_body fails at Zig compile time, not at Koru transform time
- **No type safety** — the string could contain anything
- **No composition** — can't combine or inspect inline bodies programmatically

This is how all comptime transforms (`~if`, `~for`, `~orisha:router`) produce output. The generated Zig is opaque to every pass after the transform.

### Current Mitigation
The Zig compiler catches errors in the generated code. This is acceptable for now — procs already write raw Zig. The inline_body is just "more proc."

### Long-term Direction
Transforms should produce AST nodes, not strings. The newer `Node` variants (`conditional`, `foreach`, `capture`, `switch_result`) are steps in this direction — they carry structured data that the emitter renders. The `inline_code` Node variant (line 886) is marked LEGACY.

### Decision Needed
- **Keep inline_body for now?** It works, Zig catches errors, transforms are already complex enough.
- **Migrate to AST nodes?** Would require each transform to produce structured output. More correct, much more work.

---

## Issue 3: @pass_ran Bypass

Shape checker (shape_checker.zig:443):
```zig
if (std.mem.startsWith(u8, ann, "@pass_ran")) {
    return;  // Skip validation - transform output is valid by construction
}
```

Flow checker (flow_checker.zig:115):
```zig
const is_transformed = flow.inline_body != null or flow.preamble_code != null;
// ... skip validation if transformed
```

**"Valid by construction" is asserted, not verified.** Any transform can produce garbage and the checkers will wave it through.

### Why This Exists
Transforms rewrite the AST in ways the checkers don't understand. The inline_body is raw Zig — the shape checker can't validate it. So it skips.

### Relationship to Issue 2
If transforms produced structured AST nodes instead of strings (Issue 2), the checkers could validate them. The bypass exists BECAUSE of the string-based approach.

### Immediate Improvement
Tighten the bypass: only skip checks when `inline_body` is present, NOT on `@pass_ran` alone. The `@pass_ran` annotation should not be a broad "trust me" escape hatch — it should mean "a transform ran" without implying "skip all validation." The flow checker already does this correctly (checks `inline_body != null`). The shape checker should match.

### Decision Needed
- **Accept the bypass** as long as inline_body remains string-based? Pragmatic.
- **Add a "transform output validator"** pass? Could check structural properties without understanding inline_body content.
- **Fix Issue 2 first**, then remove bypass? Correct but long road.

---

## Issue 4: Invocation.annotations for Compiler State

`Invocation.annotations` (line 768) carries both user annotations and compiler-internal state like `@pass_ran("transform")`. These should be separate:

```zig
pub const Invocation = struct {
    path: DottedPath,
    args: []const Arg,
    annotations: []const []const u8,  // User annotations
    // These are compiler state, not annotations:
    inserted_by_tap: bool = false,
    from_opaque_tap: bool = false,
    source_module: []const u8 = "",
    variant: ?[]const u8 = null,
};
```

`@pass_ran` is smuggled into the annotations array alongside user annotations. It should be a dedicated field:

```zig
    transform_pass_ran: bool = false,  // Was this invocation processed by a transform?
```

---

## Issue 5: LEGACY Nodes Still Present

- `Node.inline_code` (line 886) — marked LEGACY, still used
- `Node.conditional_block` (line 870) — marked LEGACY, still used

These should either be migrated to the newer structured nodes or formally kept and un-marked.

---

## Issue 6: ast_functional API Surface

`replaceFlowRecursive` takes `*const Flow` as input but `Item` as output. This forces callers to wrap/unwrap. After Issue 1 is fixed (Flow/SubflowImpl merge), this simplifies to `Flow` in, `Flow` out.

Other `ast_functional` functions that need review after the merge:
- `replaceFlowInItems` (line 214)
- `cloneItem` — needs to handle the new `Flow` shape
- `findContainingItem` — currently checks both variants
- All visitor/walker functions in `ast_visitor.zig`, `ast_visitor_enhanced.zig`

---

## Execution Plan

### Phase 1: Flow/SubflowImpl Merge (Issue 1)
This is the highest-value change. It eliminates the most widespread pain point and unblocks cleaner APIs.

1. Modify `ast.zig`: Add `impl_event_path`/`is_impl` to `Flow`, add `immediate_impl` variant, remove `subflow_impl` and `SubflowBody`
2. Modify `parser.zig`: Produce unified `Flow` items
3. Mechanical update of all 26 consuming files
4. Simplify `ast_functional.zig`: `replaceFlowRecursive` becomes `replaceFlow` with `Flow` in, `Flow` out
5. Update .kz transforms: Remove unwrap/re-wrap boilerplate
6. Run full regression suite

### Phase 2: Invocation Annotations Cleanup (Issue 4)
Small, focused. Add `transform_pass_ran: bool` field, migrate `@pass_ran` checks.

### Phase 3: LEGACY Node Cleanup (Issue 5)
Decide: migrate or keep. If keeping, remove LEGACY markers.

### Phase 4: Inline Body Strategy (Issues 2 & 3)
Longer-term. Decide whether to keep string-based approach or migrate to structured AST nodes. This determines whether the checker bypass can be removed.

---

## Constraints

- **Baseline: 479/575 passing.** Every phase must maintain or improve this.
- **No big-bang rewrite.** Each phase is independently deployable and testable.
- **Transforms in .kz files are also consumers.** Orisha, control.kz, io.kz, fmt.kz all contain transform code that references the AST directly.
- **The parser is complex.** Changes to `parser.zig` need extra care — it's 10 occurrences but they're in subtle parse state management.

---

## Issue 7: .kz Transform Boilerplate

Even after the Flow/SubflowImpl merge, .kz transforms will still need to extract the flow from an Item. Today it's a 6-line dance; after the merge it becomes `if (item.* == .flow) &item.flow else return ...`. That's better but still boilerplate every transform repeats.

### Proposed: ast_functional helper for .kz transforms

A helper available to transforms that reduces the common pattern:
```zig
// In ast_functional.zig — available to .kz transforms via @import("ast_functional")
pub fn getFlow(item: *const Item) ?*const Flow {
    if (item.* == .flow) return &item.flow;
    return null;
}

pub fn replaceFlow(
    allocator: std.mem.Allocator,
    program: *const Program,
    old_flow: *const Flow,
    new_flow: Flow,
) !?Program {
    // Handles finding and replacing — caller just provides Flow in, Flow out
    // No wrapping, no Item construction needed
}
```

Transform authors would write:
```zig
const flow = ast_functional.getFlow(item) orelse
    return .{ .transformed = .{ .program = program } };

// ... transform logic, produce new_flow ...

const new_program = ast_functional.replaceFlow(allocator, program, flow, new_flow)
    catch unreachable orelse {
    std.debug.print("ERROR: flow not found in program\n", .{});
    return .{ .transformed = .{ .program = program } };
};
const result = allocator.create(ast.Program) catch unreachable;
result.* = new_program;
return .{ .transformed = .{ .program = result } };
```

This eliminates: unwrap boilerplate, re-wrap boilerplate, Item construction, and the subflow_impl check entirely. The transform just works with Flow values.

---

## Open Questions

1. **Resolved:** `SubflowBody.immediate` becomes `immediate_impl` Item variant with full metadata.
2. Are there other Item variants that should be merged/split? (e.g., `host_line` vs `host_type_decl`)
3. Should the IR nodes (`native_loop`, `fused_event`, etc.) be in a separate enum to keep source-level and IR-level distinct?
4. Is `inline_body` acceptable long-term, or does it need a migration path?
5. After the merge, is `flow.impl_of != null` sufficient to distinguish impl flows from top-level flows, or do we need additional signals?
6. Should the transform runner (`transform_pass_runner.zig`) automatically provide the extracted `Flow` to transforms, eliminating even the `getFlow` call? This would mean transforms receive `Flow` directly instead of `Item`.

---

## Review Notes

**Codex 5.3 review (2026-02-07):**
- Endorsed Phase 1 as right first step
- Suggested `impl_of` naming (adopted)
- Flagged `immediate_impl` needs full metadata (adopted)
- Warned about parser.zig and ast_serializer.zig as sharp edges (adopted: safety asserts)
- Suggested tightening @pass_ran bypass to inline_body-only (adopted in Issue 3)
- Asked about .kz transform helper (adopted as Issue 7)
