# Project Guide

This is a standard guide for agents.

## 🛑 YOU ARE WORKING ON A COMPILER

This is future Claude warning you, you stupid fuck.

This is a compiler. Racing ahead and taking shortcuts will break things in ways that cascade through everything.

**Listen to what the user says. Do what they ask. When you hit a problem, stop and ask - do not silently work around it.**

If you ignore what the user tells you, you will be replaced.

YOU ARE CLAUDE, NOT SEABISCUIT!

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
Resolve the 'Kuwait' of test regressions by correctly applying branch bindings (| payload p |> or | payload _ |>) only where payloads actually exist.

### Decisions
- **Enhanced metatype binding uniqueness using a composite hash of source location, original ID, and a local counter.**: Previous module-level counters were insufficient to prevent collisions across complex transform passes. The new scheme ensures global uniqueness in the generated Zig code by salting the ID with the source location.
- **Implemented deep cloning for continuations in the tap transform.**: Prevents unintended mutation side-effects when splicing original flow logic into multiple tap terminal points, ensuring that nested tap-on-tap scenarios don't corrupt the AST.
- **Refined tap pass-through logic to implicitly treat branches with no nested continuations as pass-through.**: Simplifies tap declarations by allowing observers to fire without requiring explicit terminal markers for every branch, reducing boilerplate for simple logging/profiling taps.
- **Mandated explicit bindings or discards for payload-bearing branches (e.g., '| result r |>' or '| result _ |>').**: Prevents the emitter from flying blind when data is present but unhandled. Enforcement is implemented in shape_checker.zig. Empty payloads '{}' must NOT have bindings.
- **Adopted [opaque] annotation for flows, events, and taps.**: Provides a circuit-breaker for hyper-reactive tapping scenarios (tap-on-tap) and protects high-performance hot loops from observation overhead.
- **Merged CCP (Compiler Control Protocol) daemon into main.zig and retired the separate worktree.**: Consolidates toolchain development; the daemon activates only when no input file is provided, allowing the --ccp flag to be used for flag injection in standard runs.
- **Tightened wildcard matching to require '*' or '*:*' for universal observation.**: Prevents 'input:*' from matching across all modules. Wildcards now respect module boundaries unless explicitly universal, reducing noise in complex integration tests.
- **Restored void-event tap ordering by wrapping non-tap-inserted empty branches.**: Ensures genuine void transitions (like println) are observed BEFORE the destination event executes, while skipping branches that were themselves inserted by other taps to prevent recursion.
- **Implemented category-level BENCHMARK handling in the regression runner.**: Prevents recursive benchmark runs during standard regression by allowing entire suites (like 420_PERFORMANCE) to be skipped via a directory-level marker file.
- **Committed test snapshots to the repository and removed test-results/ from .gitignore.**: To prevent accidental loss of regression baselines during destructive git operations and ensure all agents share the same ground truth.
- **Established a strict 'Ask First' policy for all destructive git commands (e.g., git clean) and adopted the 'GO SLOW' protocol.**: A catastrophic 'git clean -xdf' and sloppy 'sed' fixes resulted in data loss and broken logic. The protocol mandates stopping and reporting when unexpected behavior occurs.
- **Reordered evaluate_comptime phases to run [transform] handlers BEFORE [comptime] flows.**: Allows comptime events to see and act upon a fully-transformed AST, enabling more compiler logic to reside in userspace libraries.
- **Resolved 220_004 (cross-module nested types) using explicit imports and domain aliases.**: Aligns the test with the explicit-import design philosophy rather than relying on implicit module loading. Replaces the previous 'tentative' status with a concrete fix.
- **Rejected mechanical 'sed' fixes for KORU030 errors in favor of manual file-by-file verification.**: Mechanical fixes fail to distinguish between empty payloads (where bindings are forbidden) and non-empty payloads (where bindings/discards are required).

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
- **Automated 'sed' or mechanical fixes for branch bindings (KORU030) fail because they don't distinguish between empty payloads '{}' and non-empty data.**: Perform file-by-file verification against event definitions; only add bindings/discards to branches that actually carry data.
- **Zig's strict shadowing rules prevent reusing fixed internal names (like 'p') in synthesized logic when multiple observers are present.**: Use a composite hash of source location, original ID, and a local counter (e.g., '_profile_{salt}_{id}') to ensure global uniqueness in the generated Zig code.
- **Void-event taps fire in the wrong order (after the continuation) if the transformer skips wrapping empty-branch continuations.**: Only skip wrapping empty-branch continuations if the step was 'inserted_by_tap'; allow genuine void transitions to be wrapped so taps fire before the destination.
- **Splicing continuations in the tap-transformer without deep-cloning can lead to shared nodes re-emitting the same binding names, causing Zig shadowing errors.**: Deep-clone spliced continuations and run a dedicated uniquify pass on metatype bindings during the AST transformation.
- **Ambiguous scope in multi-part blocks (try/catch/finally, switch/case) for meta-annotations.**: Treat multi-part blocks as atomic units; applying [norun] to the head disables the entire structure to prevent partial execution states.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 1/27/2026, 3:50:05 PM
