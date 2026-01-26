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
Finalize metatype infrastructure, stabilize wildcard tap behavior, and resolve remaining regression test failures.

### Decisions
- **Kernel DSL syntax uses a colon-prefixed naming convention (e.g., kernel:shape, kernel:init, kernel:pairwise).**: Maintains consistency with Koru's existing specialized transform patterns (e.g., ~std.types:struct) and is validated by regression tests 390_001-004.
- **Kernel execution is handled via Source bindings using pipeline syntax (e.g., | kernel k |>).**: Allows passing raw code blocks into standard library kernel blocks for specialized memory layout and GPU-expressible processing.
- **Adopted unique '_profile_<n>' binding names for metatype observers via a module-level counter.**: Zig forbids variable shadowing even in nested scopes. Deterministic counters provide safety where block isolation alone fails in the generated Zig code. This fixed the 310_044 collision issue.
- **Implementing `koru_std/logging.kz` as a first-class language feature.**: Forces improvement of the Zig-to-Koru interop story and dogfoods the standard library to replace 600+ raw debug prints.
- **Adopted string-based Handle IDs and enforced scope-local isolation with opt-in 'realms'.**: String IDs are serializable and AI-inspectable; realms allow explicit resource sharing while maintaining capability boundaries.
- **Integrated glob pattern matching into the taps.kz transform.**: Allows taps to match module-qualified and wildcard patterns (input:*) without changing core language semantics. Inlining the logic from glob_pattern_matcher.zig ensures robust prefix/suffix matching.
- **Removed the transform_taps compiler pass from the coordinate pipeline.**: The [keyword|transform] system in the userspace taps.kz library now handles tap declarations and injections, making the dedicated compiler pass redundant. Verified via --inter mode.
- **Reordered evaluate_comptime phases to run [transform] handlers BEFORE [comptime] flows.**: Allows comptime events to see and act upon a fully-transformed AST, enabling more compiler logic to reside in userspace libraries.
- **Optional branches (|?) require an explicit catch-all (|? |> _) if not all are handled.**: Prevents silent data loss and ensures developers consciously acknowledge ignored branches, aligning with Koru's philosophy of explicit intent.
- **Introduced [opaque] annotation for flows, events, and taps.**: Provides a circuit-breaker for hyper-reactive tapping scenarios (tap-on-tap) and protects high-performance hot loops from observation overhead.
- **Merged CCP (Compiler Control Protocol) daemon into main.zig.**: Consolidates toolchain development; the daemon activates only when no input file is provided, allowing the --ccp flag to be used for flag injection in standard runs.
- **Implemented std.deps for system-level dependency management.**: Allows libraries to declare system requirements (sqlite3, curl) that can be auto-installed via 'koruc deps install'.

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
- **Zig's strict shadowing rules prevent reusing fixed internal names (like 'p') in synthesized logic when multiple observers are present.**: Use a module-level counter in the transformer to generate deterministic unique bindings (e.g., '_profile_0', '_profile_1').
- **Universal wildcard taps (*:*) capture ALL events, including system meta-events (koru:start) and the tap's own internal events, leading to 'noisy' test outputs.**: Update expected.txt files to acknowledge system events or refine the tap transform to filter internal events using the [opaque] annotation.
- **Infinite recursion in universal wildcards (e.g., a tap that triggers an event which is then tapped).**: Use the [opaque] annotation on flows/events to opt-out of observation, and implement 'inserted_by_tap' tracking to prevent nested cycles.
- **Parse errors in imported modules were previously recorded but not fatal, leading to silent miscompilations.**: Ensure the compiler reporter treats errors in imported modules as fatal to expose latent bugs in the standard library.
- **Zig module system 'duplicate module' errors when importing the same file via relative paths from different modules.**: Register shared utilities (like log.zig) as named modules in build.zig and use .addImport() for all sub-modules.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 1/26/2026, 7:08:30 PM
