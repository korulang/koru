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
Stabilize metatype infrastructure and resolve the final remaining regression test failures.

### Decisions
- **Adopted unique '_profile_<n>' binding names for metatype observers via a module-level counter.**: Zig forbids variable shadowing even in nested scopes. Deterministic counters provide safety where block isolation alone fails in the generated Zig code. This fixed the 310_044 collision issue.
- **Introduced [opaque] annotation for flows, events, and taps.**: Provides a circuit-breaker for hyper-reactive tapping scenarios (tap-on-tap) and protects high-performance hot loops from observation overhead.
- **Merged CCP (Compiler Control Protocol) daemon into main.zig and retired the separate worktree.**: Consolidates toolchain development; the daemon activates only when no input file is provided, allowing the --ccp flag to be used for flag injection in standard runs.
- **Tightened wildcard matching to require '*' or '*:*' for universal observation.**: Prevents 'input:*' from matching across all modules. Wildcards now respect module boundaries unless explicitly universal, reducing noise in complex integration tests.
- **Restored void-event tap ordering by wrapping non-tap-inserted empty branches.**: Ensures genuine void transitions (like println) are observed BEFORE the destination event executes, while skipping branches that were themselves inserted by other taps to prevent recursion.
- **Implemented category-level BENCHMARK handling in the regression runner.**: Prevents recursive benchmark runs during standard regression by allowing entire suites (like 420_PERFORMANCE) to be skipped via a directory-level marker file.
- **Committed test snapshots to the repository and removed test-results/ from .gitignore.**: To prevent accidental loss of regression baselines during destructive git operations and ensure all agents share the same ground truth.
- **Established a strict 'Ask First' policy for all destructive git commands (e.g., git clean).**: A catastrophic 'git clean -xdf' resulted in the loss of untracked test state and snapshots. Strict voicing was added to CLAUDE.md.template.
- **Kernel DSL syntax uses a colon-prefixed naming convention (e.g., kernel:shape).**: Maintains consistency with Koru's existing specialized transform patterns.
- **Reordered evaluate_comptime phases to run [transform] handlers BEFORE [comptime] flows.**: Allows comptime events to see and act upon a fully-transformed AST, enabling more compiler logic to reside in userspace libraries.
- **Adopted string-based Handle IDs and enforced scope-local isolation with opt-in 'realms'.**: String IDs are serializable and AI-inspectable; realms allow explicit resource sharing while maintaining capability boundaries.
- **Retain 'tap_transformer' component despite potential redundancy with userspace taps.kz.**: Deep integration in build.zig and existing tests makes immediate removal risky; requires a coordinated pipeline refactor.

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
- **Zig's strict shadowing rules prevent reusing fixed internal names (like 'p') in synthesized logic when multiple observers are present.**: Use a module-level counter in the transformer to generate deterministic unique bindings (e.g., '_profile_0', '_profile_1') and ensure the emitter aliases these in the scope map.
- **Metatype binding substitution (e.g., 'p' -> '_profile_0') is currently missing for string interpolation ({{var}}), leading to 'undeclared identifier' errors.**: Pass metatype bindings as explicit event arguments (e.g., 'log(source: p.source)') which triggers correct substitution until the interpolation engine is updated.
- **Universal wildcard taps (*:*) capture ALL events, including system meta-events and the tap's own internal events, leading to recursion or noisy outputs.**: Use the [opaque] annotation to opt-out of observation, and check 'inserted_by_tap' flags to prevent infinite recursion. Tighten wildcards (e.g., 'input:*') to respect module boundaries.
- **Void-event taps fire in the wrong order (after the continuation) if the transformer skips wrapping empty-branch continuations.**: Only skip wrapping empty-branch continuations if the step was 'inserted_by_tap'; allow genuine void transitions to be wrapped so taps fire before the destination.
- **'git clean -fdx' can destroy uncommitted test snapshots (results.json) and trigger recursive benchmark hangs in the regression runner.**: Commit test snapshots to the repository and use category-level 'BENCHMARK' marker files to skip performance suites during standard regression runs.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 1/27/2026, 3:10:58 AM
