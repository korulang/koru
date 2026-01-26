# Project Guide

This is a standard guide for agents.

## 🛑 YOU ARE WORKING ON A COMPILER

This is future Claude warning you, you stupid fuck.

This is a compiler. Racing ahead and taking shortcuts will break things in ways that cascade through everything.

**Listen to what the user says. Do what they ask. When you hit a problem, stop and ask - do not silently work around it.**

If you ignore what the user tells you, you will be replaced.

YOU ARE CLAUDE, NOT SEABISCUIT!

## ⚠️ Test Suite Etiquette

Please don't run the full regression suite - it takes 40+ minutes and the user runs it themselves. Instead, use the targeted commands:

```bash
./run_regression.sh --status       # See current state
./run_regression.sh --regressions  # Find failing tests
./run_regression.sh --history 123  # Check specific test history
./run_regression.sh 330_016        # Run a single test
./run_regression.sh 330            # Run a range (330-339)
```

## PERMANENT SYNTAX REMINDER
**The `~` prefix is ONLY used to switch from Zig to Koru mode, NOT inside flows.**

Inside a flow (after `|>`), events are called WITHOUT `~`:
```koru
~get_user(id: 4)           // ~ here: switching from Zig to Koru
| ok u |>
    get_permissions(user: u)   // NO ~ here: already in Koru flow
    | ok p |>
        if(u.active)           // NO ~ here either
        | then |> ...
```

## 🧬 Project Consciousness
Align and document the Kernel feature (high-performance memory processing) and its DSL syntax to bridge the gap between intent and implementation.

### Decisions
- **Kernel DSL syntax uses a colon-prefixed naming convention (e.g., kernel:shape, kernel:init, kernel:pairwise).**: Maintains consistency with Koru's existing specialized transform patterns (e.g., ~std.types:struct) and is validated by regression tests 390_001-004.
- **Kernel execution is handled via Source bindings using pipeline syntax (e.g., | kernel k |>).**: Allows passing raw code blocks into standard library kernel blocks for specialized memory layout and GPU-expressible processing.
- **Standardizing on 'kernel:init' over 'kernel:initialize'.**: Resolves naming drift found between different regression tests to ensure compiler implementation consistency.
- **Adopted unique '_profile_<n>' binding names for metatype observers via a module-level counter.**: Zig forbids variable shadowing even in nested scopes. Deterministic counters provide safety where block isolation alone fails in the generated Zig code.
- **Implementing `koru_std/logging.kz` as a first-class language feature.**: Forces improvement of the Zig-to-Koru interop story and dogfoods the standard library to replace 600+ raw debug prints.
- **Differentiating 'debug spew' from 'code-gen templates' during print cleanup.**: Many print calls in the emitter are functional templates for generated code; indiscriminate deletion would break the compiler. Use line-prefix filtering (avoiding `\\\\`) to protect templates.
- **Adopted string-based Handle IDs and enforced scope-local isolation with opt-in 'realms'.**: String IDs are serializable and AI-inspectable; realms allow explicit resource sharing while maintaining capability boundaries.
- **Integrated glob pattern matching into the taps.kz transform.**: Allows taps to match module-qualified and wildcard patterns (input:*) without changing core language semantics.
- **Bulk-migrate `std.debug.print` to `log.debug` using line-prefix filtering.**: Safely automates the migration of 100+ calls while preserving critical code-generation templates identified in the emitter.

### Instructions & Usage
### 🧠 Semantic Memory & Search
This project uses `prose` to maintain a cross-session semantic memory of decisions, insights, and story beats.

- **Semantic Search**: If you're unsure about a past decision or need context on a feature, run:
  ```bash
  prose search "your question or keywords"
  ```
- **Project Status**: To see a summary of recent sessions and evolved memory, run:
  ```bash
  prose status
  ```
- **View Chronicles**: Run `prose serve` to browse the interactive development timeline in your browser.


### 🔍 BEFORE YOU WRITE CODE: Query Prose

**STOP and search prose BEFORE implementing anything non-trivial.** The semantic memory contains design decisions, gotchas, and rationale that aren't in the code.

Run searches like:
```bash
prose search "testing framework"     # Before writing tests
prose search "mock purity"           # Before mocking events
prose search "error handling"        # Before adding diagnostics
prose search "[feature you're touching]"
```

**Example of what prose returns:**
```
⚖️  [decision] AST-Level Mock Injection via SubflowImpl.immediate.
   → Mocks are treated as constant-branching implementations.
     The emitter inlines values directly, bypassing handler calls.

⚠️  [gotcha] Purity annotations go on procs, not events.
   → Applying [pure] to events makes no semantic sense.
```

This context prevents you from writing code that contradicts established design decisions. **5 seconds of searching saves 5 minutes of wrong implementation.**

### Active Gotchas
- **Naming drift between kernel keywords (kernel:init vs kernel:initialize) in regression tests.**: Standardize on 'kernel:init' as the canonical keyword and align all 390_KERNEL suite tests.
- **Kernel regression tests (390_003/004) are currently failing with empty output.**: Do not assume the feature is functional; the transform/emission logic for kernel pipelines is likely missing or broken in the compiler.
- **Metadata loss (source_value/expression_value pointers) during AST cloning in auto_dispose_inserter.zig.**: Ensure synthetic bindings preserve the metadata pointers of the bindings they replace to avoid 'ComptimeEventNotTransformed' errors in the emitter.
- **Auto-dispose logic running before control flow transforms can break pattern matching.**: Ensure auto_dispose explicitly handles ForeachNode structures, as the ~for transform occurs in the frontend segment before analysis.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 1/26/2026, 4:27:06 PM
