# Hello World Example

The simplest Koru program. Generated using `koruc create exe`.

## What It Does

Prints "Hello from hello-world!" to the console.

## The Code

```koru
~import "$std/io"

~io:println(text: "Hello from hello-world!")
```

- **Import**: Uses the standard library I/O module via `$std/io`
- **Module qualifier**: `io:println` calls the println event from the imported module
- **Top-level flow**: Starts execution automatically

## Running

```bash
koruc run src/main.kz
```

Or build and run separately:
```bash
koruc build src/main.kz
./a.out
```

## Features Demonstrated

- ✅ Project structure (koru.json, src/, lib/)
- ✅ Standard library imports
- ✅ Module system
- ✅ Top-level flow execution
- ✅ Basic I/O

**This is the baseline** - if this doesn't work, nothing else will!

## Learn More

- [Koru Language Specification](../../SPEC.md)
