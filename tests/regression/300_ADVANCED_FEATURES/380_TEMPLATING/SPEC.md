# 380 Templating Specification

Koru's templating system uses Liquid syntax to generate code at compile time.
Templates receive context from event arguments, enabling powerful metaprogramming.

## Core Concept

The `~emit` event takes a template string as its first argument and named args as context.
The Liquid engine processes `{{ variable }}` and `{% if %}` blocks at compile time.

## Syntax

### Basic Interpolation

```koru
~import "$std/liquid_template"

~emit("Hello {{ name }}!", name: "Alice")
// Output: Hello Alice!
```

### Conditionals

```koru
~emit("{% if is_debug %}[DEBUG] {{ msg }}{% endif %}", is_debug: "true", msg: "trace")
// Output: [DEBUG] trace
```

### Multiple Variables

```koru
~emit("{{ greeting }}, {{ name }}! You have {{ count }} messages.",
      greeting: "Hello", name: "Bob", count: "5")
// Output: Hello, Bob! You have 5 messages.
```

## Liquid Syntax Support

| Syntax | Description |
|--------|-------------|
| `{{ var }}` | Output value from context |
| `{% if key %}...{% endif %}` | Conditional block (truthy = non-empty string) |
| `{% unless key %}...{% endunless %}` | Inverted conditional |
| `{% for item in array %}...{% endfor %}` | Iteration (requires array context) |

## Implementation

The Liquid engine lives in `src/liquid.zig`. The `emit` event is a transform that:

1. Extracts the template from the first (Expression) argument
2. Builds a Liquid context from named arguments
3. Renders the template via `liquid.render()`
4. Generates inline Zig print code with the result

## Files

- `src/liquid.zig` - Liquid template engine
- `koru_std/liquid_template.kz` - The `emit` event and transform

## Status

- [x] Liquid engine implemented (`src/liquid.zig`)
- [x] Basic interpolation (`{{ variable }}`)
- [x] Conditionals (`{% if %}`, `{% unless %}`)
- [x] `emit` event with Expression + named args
- [ ] Source metadata in context (`{{ source.file }}`, etc.)
- [ ] Compiler flags/env in context
- [ ] Scope capture (bindings visible at call site)
- [ ] Program access for transforms
