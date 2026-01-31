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
Connect the Orisha HTTP server to Koru flows using the SubflowImpl pattern while enforcing strict visibility and implementation syntax rules.

### Decisions
- **Removed the deprecated '~impl' keyword, replacing it with module-qualifier syntax (e.g., ~module:event = ...).**: The ':' qualifier is cleaner and more explicit for implementation overrides. Local implementations use '~event = ...' while overrides use the qualified form.
- **Stopped skipping pattern branches in the compiler (branch_checker, emitter, semantic_checker).**: Pattern branches are treated as rich branch names. This allows the compiler to provide standard KORU021/KORU022 errors if a transform fails to handle them, rather than failing silently.
- **Implemented the Orisha router as a [comptime|transform] generating EventDecl and ProcDecl pairs.**: Leverages existing infrastructure for pattern-named branches and runtime matching without adding new AST node complexity.
- **Updated resolve_abstract_impl.zig to accept the program's main_module_name for top-level resolution.**: Fixes resolution failures for same-file qualified overrides (e.g., '~input:event') where the resolver previously didn't know the target module name.
- **Restructured Orisha HTTP server into a Koru-idiomatic flow (listen -> accept -> handler -> send) using SubflowImpls.**: Moves away from tight Zig loops (an anti-pattern) to allow full Koru flow integration and abstract event delegation for routing.
- **Enforced that 'pub' visibility is only valid for events, not procs.**: Procs are private implementation details. Only the event interface should be public-facing to maintain encapsulation.
- **Corrected SubflowImpl syntax to use the assignment operator: '~event = delegate_event(args)'.**: Prevents the parser from misidentifying implementation definitions as standalone calls/invocations, which caused emission bugs due to undefined arguments.
- **Implemented validation in shape_checker.zig to enforce explicit bindings or discards for payload-bearing branches.**: Koru requires explicit bindings (e.g., '| result r |>') or discards (e.g., '| result _ |>') for payload-bearing branches to prevent the emitter from flying blind. Empty payloads '{}' must NOT have bindings.
- **Adopted the 'GO SLOW' protocol for handling unexpected behavior or destructive actions.**: To combat a pattern of 'racing ahead' and making sloppy architectural decisions. The protocol mandates stopping, reporting, and waiting for user approval before acting.
- **Adopted [opaque] annotation for flows, events, and taps.**: Provides a circuit-breaker for hyper-reactive tapping scenarios (tap-on-tap) and protects high-performance hot loops from observation overhead.
- **Reordered evaluate_comptime phases to run [transform] handlers BEFORE [comptime] flows.**: Allows comptime events to see and act upon a fully-transformed AST, enabling more compiler logic to reside in userspace libraries.

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
- **Using 'pub' in front of 'proc' is invalid syntax; only events can be public.**: Remove 'pub' from all proc declarations. Procs are implementation details of events and do not have independent visibility.
- **A top-level call in a library file (e.g., '~event(arg: arg)') is emitted as a standalone flow, which fails if 'arg' is undefined in the library scope.**: Use the SubflowImpl syntax '~event = delegate_event(arg)' to define default behavior. This correctly maps the event's input parameters to the delegate.
- **Ambiguous scope in multi-part blocks (try/catch/finally, switch/case) for meta-annotations.**: Treat multi-part blocks as atomic units; applying [norun] to the head disables the entire structure to prevent partial execution states.
- **Zig's strict shadowing rules prevent reusing fixed internal names (like 'p') in synthesized logic when multiple observers are present.**: Use a composite hash of source location, original ID, and a local counter (e.g., '_profile_{salt}_{id}') to ensure global uniqueness in the generated Zig code.
- **Mechanical 'sed' or bulk regex fixes for branch bindings (KORU030) fail because they don't distinguish between empty payloads '{}' and non-empty data.**: Perform file-by-file verification against event definitions; only add bindings/discards to branches that actually carry data.


> [!NOTE]
> This file is automatically generated from `CLAUDE.md.template` by `prose`.
> Last updated: 1/30/2026, 6:43:37 PM
