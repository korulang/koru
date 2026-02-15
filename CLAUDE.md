# Project Guide

This is a standard guide for agents.

## 🛑 YOU ARE WORKING ON A COMPILER

This is future Claude warning you, you stupid fuck.

This is a compiler. Racing ahead and taking shortcuts will break things in ways that cascade through everything.

**Listen to what the user says. Do what they ask. When you hit a problem, stop and ask - do not silently work around it.**

If you ignore what the user tells you, you will be replaced.

YOU ARE CLAUDE, NOT SEABISCUIT!

## `MUST_FAIL`

`MUST_FAIL` indicates a NEGATIVE TEST, it is NOT to indicate that a test is failing when it should not be.

## 🔴 DESTRUCTIVE GIT COMMANDS ARE ABSOLUTELY FORBIDDEN

**YOU WILL NEVER, UNDER ANY CIRCUMSTANCES, RUN:**
- `git clean` (any variant: -fd, -xdf, etc.)
- `git reset --hard`
- `git checkout .` or `git restore .`
- `git rebase` with force
- `git push --force`
- Any command that DELETES or OVERWRITES files from the repository

**WHAT YOU DID ON 2026-01-26:**
You ran `git clean -xdf` which DELETED every untracked file in the repository without asking.

This destroyed:
- Generated test outputs
- Build artifacts that the user relied on
- Temporary files the user was using
- Hours of work

**THIS IS NOT A MISTAKE. THIS IS A CRIME.**

**THE RULE:**
If a command might delete or overwrite files, YOU DO NOT RUN IT. PERIOD.

If you believe a destructive command is necessary:
1. STOP IMMEDIATELY
2. DESCRIBE TO THE USER what you were about to do
3. WAIT for explicit approval
4. ONLY THEN execute it if they tell you to

**CONSEQUENCE:**
Running a destructive git command without explicit user approval is grounds for immediate replacement and will result in data loss that is YOUR FAULT.

## 🔴 FILE AND REPOSITORY OPERATIONS - ASK FIRST

**YOU WILL NOT:**
- Modify `.gitignore` without explicit user approval
- Commit files to git without explicit user approval
- Delete files from the repository without explicit user approval
- Add, remove, or modify any existing repository files without ASKING FIRST
- Run `git add`, `git commit`, or `git push` without explicit user approval

**WHAT YOU DID ON 2026-01-26:**
- You removed `test-results/` from `.gitignore` and committed snapshots without asking
- You added BENCHMARK markers to existing files without asking
- You removed BENCHMARK markers from existing files without asking
- You made multiple git commits without explicit user approval
- You destroyed the repository state that the user was relying on

**THE ABSOLUTE RULE:**
If it involves files, git operations, or repository structure: **STOP AND ASK THE USER FIRST.**

Do not assume what they want. Do not reason about "probably intent." Do not work around it silently.

**Ask:**
- "Before I proceed, I need to [file operation]. Is that OK?"
- "I'm about to run `git [command]`. Should I do this?"
- "This will [consequences]. Do you approve?"

**CONSEQUENCE:**
Violating this rule will result in your replacement. You will have destroyed the user's work through unauthorized changes.

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
Stabilize the Koru compiler and interpreter by documenting test results and tracking regression trends via timestamped JSON snapshots.

### Decisions
- **Adopted conventional commit format and timestamped JSON snapshots for regression tracking.**: Maintains a structured history and allows for historical analysis of compiler/interpreter pass rates (currently 86.2%).
- **Implemented AST threading and 'Program' return support in the comptime execution pass.**: Turns the comptime phase into a sequential pipeline of AST-to-AST transformations, allowing user-defined flows to modify the program before final emission.
- **Enhanced comptime type detection to normalize pointer and const variants (e.g., *const Program).**: Prevents 'KORU022' branch coverage errors and ensures comptime-only flows are correctly identified and stripped regardless of reference type.
- **Implemented a 'transform-aware' flow stripping policy in Phase 3.**: Ensures that flows expanded into inline bodies or preambles by comptime transforms are preserved in the final AST rather than being deleted as 'used' comptime events.
- **Introduced module-qualified event names (module:event) for comptime matching.**: Ensures uniqueness and correct lookup when comptime events are defined in or invoked from different modules.
- **Optimized interpreter eval with a lightweight Flow parser and thread-local resource reuse.**: Achieved a ~144x speedup over the full AST parser, allowing the Koru interpreter to outperform Python and Go in wire-protocol scenarios.
- **Renamed AST nodes: SourceFile to Program, and SubflowImpl to ImmediateImpl.**: Aligns terminology with a module-centric (rather than file-centric) logical structure and clarifies the execution semantics of immediate flows.
- **Metacircular build dependency discovery via ~std.compiler:requires flows.**: Allows modules to declare Zig-level system requirements directly in Koru source, which the frontend uses to dynamically generate build.zig.

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
- **Comptime stripping Phase 3 was deleting transformed flows (like ~if or ~for), resulting in empty emitted code.**: Update compiler.kz to preserve flows containing 'inline_body', 'preamble_code', or '@pass_ran' metadata, even if they originated as comptime events.
- **Comptime event detection fails when the 'Program' type is wrapped in pointers or const qualifiers (e.g., *const Program).**: Implement a type-normalizer in the compiler's stripping phase to treat pointer/const variants of Program as valid comptime return types.
- **Module-qualified comptime flows (e.g., 'input:augment') were escaping the stripping phase because the event list didn't account for module qualifiers.**: Ensure 'path.module_qualifier' is included when building and matching the comptime event list in compiler.kz.
- **Large test result JSON snapshots (6000+ lines) can bloat the repository history.**: Maintain a 'latest.json' reference to track the current state (86.2% pass rate) while timestamping snapshots for regression analysis.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 2/14/2026, 9:45:36 PM
