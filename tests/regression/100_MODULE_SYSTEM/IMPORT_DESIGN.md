# Import System Design: Auto-Import Patterns

**Status**: ✅ Implemented (2025-11-27)

## Design Rationale

### Why Auto-Import Parents?

When you import `$std/io/file`, you're expressing interest in file I/O. The parent `io.kz` likely contains utilities that file operations depend on (like `println` for logging). Requiring explicit import of both would be tedious and error-prone.

**The path hierarchy implies the dependency.**

### Why Auto-Import Index?

The `index.kz` at a library's root provides:
- Root-level utilities (like `panic`, `assert`)
- Future home for `[keyword]`-annotated events
- Common types every user of the library needs

When you import anything from `$std/*`, you implicitly want the stdlib's core utilities.

### Both Are Optional

If the parent or index file doesn't exist, the import silently succeeds. This allows:
- Pure organizational directories (no parent `.kz` file)
- Libraries without an index
- Gradual adoption of the pattern

### Deduplication

Multiple imports from the same library only import shared parents/index once. The import system tracks canonical paths.

## Tests (Source of Truth)

See the test files for exact behavior:

- `110_012_auto_import_parent/` - Parent auto-import
- `110_012_optional_parent/` - Optional parent behavior
- `110_014_auto_import_index/` - Index auto-import

---

*Design: 2025-10-21 | Implementation: 2025-11-27*
