# Codex Tasks

Task descriptions for OpenAI Codex to work on. Codex analyzes the codebase and proposes changes on branches for us to test and merge.

## Workflow

1. We identify a well-contained problem through conversation
2. We write a task description here with full context
3. Codex reads it, analyzes relevant files, makes changes on a branch
4. We pull the branch, run tests, iterate or merge

## Constraints

- Codex cannot run our test suite (no Zig in the image)
- Codex proposes, we validate
- Each task should be self-contained with clear success criteria

## Task Format

Each task file should include:
- **Problem**: What's broken, with specific errors
- **Context**: How the system works, which files matter
- **Success Criteria**: Which tests should pass
- **Files to Examine**: Starting points
- **Constraints**: What not to break
