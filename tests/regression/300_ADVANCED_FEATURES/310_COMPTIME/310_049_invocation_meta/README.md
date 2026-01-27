# InvocationMeta Test

Tests that `InvocationMeta` provides call site metadata for comptime introspection.

## Feature

`InvocationMeta` is a special type that can be used in comptime event parameters. When a proc receives an `InvocationMeta` parameter, the compiler automatically injects:

- `path`: Full event path (e.g., "std.build:variants")
- `module`: Module qualifier or null
- `event_name`: Just the event name
- `annotations`: Flow annotations from the call site (e.g., `["release"]`, `["debug"]`)
- `location`: Source location of the invocation

## Usage

```koru
~[comptime]pub event my_event { meta: InvocationMeta }
| configured {}

~proc my_event {
    // meta.annotations contains flow annotations
    if (meta.annotations.len > 0) {
        // Do something based on annotation
    }
}

// Call with annotation
~[release]my_event()

// Call without annotation
~my_event()
```

## Use Case: Build Variants

This enables the `build:variants` feature where different variant configurations can be selected based on annotations:

```koru
~[release]std.build:variants {
    "compute": "fast",
    "blur": "gpu"
}

~[debug]std.build:variants {
    "compute": "naive",
    "blur": "cpu"
}
```

The comptime proc can check `meta.annotations` against a `--build=release` flag to select the appropriate configuration.
