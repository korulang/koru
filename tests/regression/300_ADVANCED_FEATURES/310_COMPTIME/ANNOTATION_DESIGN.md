# Compiler Annotation Design

**Status:** Specified in tests 602b, 603, 604, 605 - awaiting implementation

**Philosophy:** Keep parser dumb, store opaque strings, let compile-time code interpret them.

---

## Syntax

### Inline Format (for short lists)

```koru
~[comptime|runtime|fuseable] event foo {}
```

**Delimiter:** `|` character

**Produces AST:**
```json
{
  "annotations": ["comptime", "runtime", "fuseable"]
}
```

### Vertical Format (for long lists)

```koru
~[
-comptime
-runtime
-optimize(level: 3)
-inline(threshold: 500)
-gpu(target: "metal", precision: "half")
] event complex {}
```

**Bullet:** `-` character (markdown-style!)

**Produces SAME AST:**
```json
{
  "annotations": [
    "comptime",
    "runtime",
    "optimize(level: 3)",
    "inline(threshold: 500)",
    "gpu(target: \"metal\", precision: \"half\")"
  ]
}
```

**Key insight:** Inline and vertical produce identical AST - choose based on readability!

---

## Parser Behavior

### What Parser DOES (minimal!)

1. **Recognize syntax:** `~[...]` before event/proc declarations
2. **Split on delimiters:**
   - Inline mode (single line): Split on `|`
   - Vertical mode (multi-line): Split on `-` bullet prefix
3. **Store as array of strings:** No interpretation, no parsing inside strings
4. **Strip whitespace:** Leading/trailing whitespace removed from each annotation

### What Parser DOES NOT DO

❌ Parse inside annotation strings
❌ Validate annotation names
❌ Parse parameters like `(level: 3)`
❌ Understand annotation semantics
❌ Enforce any structure

**Annotations are OPAQUE STRINGS to the parser!**

---

## Storage Format

### AST Representation

```zig
pub const EventDecl = struct {
    name: []const u8,
    annotations: [][]const u8,  // Array of opaque strings
    // ... other fields
};
```

### JSON Serialization (`--ast-json`)

```json
{
  "type": "event_decl",
  "name": "optimized_compute",
  "annotations": [
    "comptime",
    "runtime",
    "optimize(level: 3)",
    "gpu:metal:half"
  ]
}
```

**All strings are opaque!** Compile-time code decides how to parse them.

---

## Compile-Time Interpretation

### Standard Library Helpers

```koru
// In $std/compiler/annotations.kz

// Check if annotation exists (exact match)
~proc has_annotation {
    annotations: [][]const u8,
    name: []const u8
} -> bool

// Get annotation starting with prefix
~proc get_annotation {
    annotations: [][]const u8,
    prefix: []const u8
} -> ?[]const u8

// Parse parameter from annotation string
~proc parse_param {
    annot: []const u8,
    pattern: []const u8
} -> ?i32
```

### Example: Compiler Pass Reading Annotations

```koru
~[comptime] proc apply_optimizations { event: EventAST }
| optimized { event: EventAST }

~proc apply_optimizations {
    // Simple flag check
    if (has_annotation(event.annotations, "comptime")) {
        emit_to_backend(event);
    }

    // Parameterized annotation
    if (get_annotation(event.annotations, "optimize")) |opt| {
        // opt = "optimize(level: 3)"
        const level = parse_param(opt, "level") orelse 1;

        if (level >= 3) {
            event = inline_all_calls(event);
            event = constant_fold(event);
        }
    }

    // Custom format (your parser!)
    if (get_annotation(event.annotations, "gpu:")) |gpu| {
        // gpu = "gpu:metal:half"
        const parts = split(gpu, ":");
        const backend = parts[1];  // "metal"
        const precision = parts[2]; // "half"
        event = compile_for_gpu(event, backend, precision);
    }

    return .{ .optimized = .{ .event = event } };
}
```

---

## Annotation Format Examples

### Standard Flags

```koru
~[comptime]
~[runtime]
~[fuseable]
~[inline]
```

Stored as: `["comptime"]`, `["runtime"]`, etc.

### Parameterized (Key-Value Style)

```koru
~[optimize(level: 3)]
~[inline(threshold: 500)]
~[gpu(target: "metal", precision: "half")]
```

Stored as opaque strings:
- `"optimize(level: 3)"`
- `"inline(threshold: 500)"`
- `"gpu(target: \"metal\", precision: \"half\")"`

Compile-time code parses parameters as needed.

### Colon-Separated (Custom Format)

```koru
~[gpu:metal:half]
~[profile:1000Hz:100samples]
```

Stored as: `"gpu:metal:half"`, `"profile:1000Hz:100samples"`

Your compiler pass decides what colons mean!

### At-Sign Syntax (Experimental)

```koru
~[inline@500]
~[cache@aggressive]
```

Stored as: `"inline@500"`, `"cache@aggressive"`

Future syntax experiments? Go for it!

### URLs/Paths (Why not?)

```koru
~[source("https://spec.example.com/v2")]
~[doc("/path/to/doc.md")]
```

Stored as opaque strings with quotes preserved.

### Complex Nesting

```koru
~[custom(foo(bar: 1, baz: nested(x: 2)))]
```

Stored as: `"custom(foo(bar: 1, baz: nested(x: 2)))"`

Parser doesn't care about nesting - it's all just a string!

---

## Design Rationale

### Why Opaque Strings?

**Flexibility:**
- Add new annotation formats without parser changes
- Experiment with syntax at compile-time
- User-defined annotations with custom parsers

**Simplicity:**
- Parser stays minimal (split on delimiters)
- No grammar for annotation internals
- No breaking changes when adding features

**Unix Philosophy:**
- Parser: One job (recognize `~[...]`, split strings)
- Compiler helpers: Different job (parse annotation contents)
- Separation of concerns!

### Why Vertical `-` Bullets?

**Readability:**
```koru
// Hard to scan
~[comptime|runtime|optimize(level:3)|inline(threshold:500)|gpu(target:"metal")]

// Easy to scan
~[
-comptime
-runtime
-optimize(level: 3)
-inline(threshold: 500)
-gpu(target: "metal")
]
```

**Markdown consistency:**
- Developers already know `-` means "list item"
- Looks like markdown bullet lists
- Familiar and intuitive

**AI-friendly:**
- Vertical scanning is easier for AI models
- Clear structure (each line = one annotation)
- Easy to add/remove during code generation

### Why NOT Parse Parameters?

If parser did this:
```json
{"name": "optimize", "args": {"level": 3}}
```

**You've locked yourself into:**
- Parameters MUST be key-value pairs
- Syntax MUST be `name(key: value)`
- No alternative formats allowed
- Parser change needed for new syntax

**With opaque strings:**
- Any syntax works: `optimize(level: 3)`, `optimize:level:3`, `optimize@3`
- Compile-time code decides how to parse
- Experiment freely!
- Maximum forward compatibility

---

## Evolution Path

**Phase 1 (now):** Parser accepts syntax, stores strings
```koru
~[comptime|runtime]
```

**Phase 2:** Standard library helpers for common patterns
```koru
has_annotation(annotations, "comptime")
get_annotation(annotations, "optimize")
```

**Phase 3:** User-defined compiler passes
```koru
~[comptime] proc my_custom_optimization { ... }
```

**Phase 4:** Annotation-driven metaprogramming!
```koru
~[
-my_custom_pass(mode: "experimental")
-logging(level: "verbose", output: "/tmp/log")
]
```

---

## Implementation Checklist

For parser implementation:

- [ ] Recognize `~[...]` before event/proc declarations
- [ ] Inline mode: Split on `|` delimiter
- [ ] Vertical mode: Recognize `-` prefix, collect until `]`
- [ ] Store array of opaque strings in AST
- [ ] Serialize to JSON as `"annotations": ["...", "..."]`
- [ ] Strip leading/trailing whitespace from each annotation
- [ ] **DO NOT** parse inside annotation strings
- [ ] **DO NOT** validate annotation names
- [ ] **DO NOT** interpret semantics

For standard library:

- [ ] Create `$std/compiler/annotations.kz`
- [ ] Implement `has_annotation(annotations, name)`
- [ ] Implement `get_annotation(annotations, prefix)`
- [ ] Implement `parse_param(annot, key)` for key-value parsing
- [ ] Document common patterns and conventions

---

## Tests

- **602b_annotations_in_ast** - Annotations appear in AST JSON
- **603_annotation_inline_syntax** - Inline `|` delimiter syntax
- **604_annotation_vertical_syntax** - Vertical `-` bullet syntax
- **605_annotation_edge_cases** - Weird formats stored as opaque strings

All tests verify using `--ast-json` that annotations appear as opaque string arrays.

---

*Design Discussion: 2025-10-21*
*"Keep parser dumb. Let compile-time code be smart."*
