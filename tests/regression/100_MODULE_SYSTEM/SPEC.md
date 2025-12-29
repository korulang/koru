# Import Specification

> Module system for organizing and reusing Koru code across files and directories.

📚 **[Back to Main Spec Index](../../../SPEC.md)**

**Last Updated**: 2025-10-26
**Test Range**: 151-164

---

## Overview

Koru's import system enables modular code organization through directory-based namespacing. Unlike traditional module systems, Koru uses **directory structure** to create automatic namespaces, making large codebases naturally organized.

**Key Features**:
- Directory imports create two-level namespaces: `package.module:event()`
- Public/private visibility control with `~pub` marker
- Import aliasing for custom namespace names
- Standard library imports with `$std/` prefix
- Automatic namespace collision prevention

---

## Basic Import Syntax

### File Import

```koru
~import "module_name"
```

Imports a single `.kz` file, making its public events available:
- **Module name**: Filename (without `.kz`)
- **Event access**: `module:event()`

**Example**:
```koru
~import "helper"

// Access events from helper.kz
~helper:greet(name: "World")
| greeted g |> _
```

See: [150_file_import_basic](150_file_import_basic/)

### Directory Import

```koru
~import "directory_path"
```

Imports all `.kz` files from a directory, creating a namespace hierarchy:
- **Package name**: Directory name (last component)
- **Module name**: Filename (without `.kz`)
- **Event access**: `package.module:event()`

**Example**:
```koru
~import "lib/raylib"

// Access events from raylib/graphics.kz
~raylib.graphics:render(width: 1920, height: 1080)
| drawn d |> _

// Access events from raylib/audio.kz
~raylib.audio:play(sound_id: 42)
| playing |> _
```

See: [156_dir_import_basic](156_dir_import_basic/)

---

## Import Aliasing

There is NO support for import aliasing. ANY DOCUMENTATION THAT REFERS TO THIS IS OUT OF DATE AND SHOULD BE REPORTED.

---

## Public vs Private Events

### Public Events

Events marked with `~pub` can be imported:

```koru
// In lib/math.kz
~pub event add { a: i32, b: i32 }
| result { value: i32 }
```

```koru
// In main.kz
~import "lib"

~lib.math:add(a: 5, b: 3)
| result r |> _
```

### Private Events

Events without `~pub` are **module-private** and cannot be imported:

```koru
// In lib/internal.kz
~event helper { x: i32 }  // NOT public
| done {}
```

```koru
// In main.kz
~import "lib"

~lib.internal:helper(x: 42)  // ❌ PARSE ERROR: helper is not public
```

**Design rationale**: Explicit public markers prevent accidental API exposure.

See: [151_directory_import_basic](151_directory_import_basic/) (failure case), [152_directory_import_public](152_directory_import_public/) (success case)

---

## Namespace Hierarchy

### Two-Level Namespace

Directory imports create a two-level namespace:
1. **Package**: Directory name
2. **Module**: Filename (without `.kz`)

**Directory structure**:
```
lib/
  raylib/
    graphics.kz  → raylib.graphics:*
    audio.kz     → raylib.audio:*
    physics.kz   → raylib.physics:*
```

**Usage**:
```koru
~import "lib/raylib"

~raylib.graphics:init()
~raylib.audio:init()
~raylib.physics:init()
```

### Dotted Event Names

Events can use dots for internal namespacing:

```koru
// In graphics.kz
~pub event z_buffer.render { width: i32, height: i32 }
| drawn {}

~pub event sprite.draw { x: i32, y: i32 }
| drawn {}
```

**Full hierarchy**: `package.module:category.event()`

```koru
~import "lib/raylib"

// package.module:category.event()
~raylib.graphics:z_buffer.render(width: 1024, height: 768)
| drawn |> raylib.graphics:sprite.draw(x: 100, y: 200)
    | drawn |> _
```

See: [159_dir_import_dotted](159_dir_import_dotted/)

---

## Namespace Collision Prevention

Multiple modules can have events with the **same name** without colliding:

**Directory structure**:
```
engine/
  graphics.kz  → ~pub event init {}
  audio.kz     → ~pub event init {}
  physics.kz   → ~pub event init {}
```

**Usage**:
```koru
~import "engine"

// All three "init" events coexist peacefully!
~engine.graphics:init()
| done |> _

~engine.audio:init()
| done |> _

~engine.physics:init()
| done |> _
```

**Why this works**: The module name (`graphics`, `audio`, `physics`) provides automatic namespacing.

See: [157_directory_namespace_collision](157_directory_namespace_collision/)

---

## Configuring Library Paths with `koru.json`

The `koru.json` file configures project-level settings, including custom library path mappings for `$`-prefixed imports.

### Basic Configuration

**koru.json:**
```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    
    .paths = .{
        .std = "koru_std",
        .src = "src",
        .lib = "lib",
    },
}
```

**Usage:**
```koru
~import "$std/io"        // Resolves to ./koru_std/io/ relative to koru.json-file or absolute path
~import "$lib/utils"     // Resolves to ./lib/utils/ relative to koru.json-file
```

### Project Structure

```
my-project/
├── koru.json              # Project configuration
├── src/
│   └── main.kz           # Entry point
├── lib/                  # Your own modules
│   ├── utils/
│   │   └── helpers.kz
│   └── common/
│       └── types.kz
└── koru_std/             # Custom stdlib location (if overridden)
```

**Import from your lib:**
```koru
~import "$lib/utils"      // Imports lib/utils/
~import "$lib/common"     // Imports lib/common/
```

### Path Resolution Priority

1. **`$std/*`** - Standard library (configured in `.imports.std` or default)
2. **`$lib/*`** - Project libraries (configured in `.imports.lib` or default to `./lib`)
3. **Custom `$` prefixes** - Any custom mappings in `.imports`
4. **Relative paths** - `./` and `../` for same-project imports
5. **Bare paths** - Resolved relative to current file

**Example with multiple custom paths:**
```zig
.{
    .imports = .{
        .std = "./koru_std",
        .lib = "./lib",
        .vendor = "./vendor",     // Custom: $vendor/*
        .internal = "./internal", // Custom: $internal/*
    },
}
```

```koru
~import "$std/io"           // ./koru_std/io/
~import "$lib/utils"        // ./lib/utils/
~import "$vendor/raylib"    // ./vendor/raylib/
~import "$internal/core"    // ./internal/core/
```

### Benefits

- **Consistent imports**: `$std/io` works regardless of file location
- **Easy refactoring**: Move files without changing imports
- **Clear intent**: `$`-prefix signals external/library code
- **Project organization**: Separate user code from libraries

---

## Multi-Module Flows

Complex flows can use multiple modules from the same package:

```koru
~import "lib/net"

// HTTP server using multiple net modules
~net.tcp:server.listen(port: 8080)
| listening l |> net.tcp:server.accept(server_id: l.server_id)
    | connection c |> net.tcp:connection.read(conn_id: c.conn_id)
        | data d |> net.http:request.parse(bytes: d.bytes)
            | request r |> net.http:response.build(status: 200, body: "OK")
                | response resp |> net.tcp:connection.write(conn_id: c.conn_id, data: resp.bytes)
                    | sent |> _
                    | failed |> _
            | invalid |> net.http:response.build(status: 400, body: "Bad Request")
                | response resp |> net.tcp:connection.write(conn_id: c.conn_id, data: resp.bytes)
                    | sent |> _
                    | failed |> _
        | closed |> _
        | failed |> _
    | failed |> _
| failed |> _
```

**Pattern**: Related functionality grouped in a single package, accessed through different modules.

See: [160_dir_import_flow](160_dir_import_flow/)

---

## Realistic Patterns

### File Processing Pipeline

```koru
~import "lib/io"

// Read → Parse → Transform → Write
~io.file:read(path: "input.txt")
| success s |> io.parse:lines(text: s.contents)
    | parsed p |> io.transform:uppercase(text: s.contents)
        | transformed t |> io.file:write(path: "output.txt", data: t.result)
            | written |> _
            | ioerror |> _
| notfound |> _
| ioerror |> _
```

See: [153_file_processor](153_file_processor/)

### Error Handling Across Modules

```koru
~import "lib/db"

~db.connection:open(host: "localhost")
| connected c |> db.query:execute(conn: c.handle, sql: "SELECT * FROM users")
    | rows r |> db.result:process(data: r.data)
        | success |> _
        | error |> _
    | error e |> db.connection:close(conn: c.handle)
        | closed |> _
| error |> _
```

See: [154_deep_error_handling](154_deep_error_handling/)

---

## Implementation Details

### Module Resolution

1. **Parse import statement**: Extract directory path
2. **Scan directory**: Find all `.kz` files
3. **Create namespace**: Use directory name as package, filenames as modules
4. **Parse each file**: Extract public events
5. **Build symbol table**: Map `package.module:event` to event definitions

### Generated Code Structure

```zig
// For: ~import "lib/raylib"
pub const raylib = struct {
    pub const graphics = @import("lib/raylib/graphics.kz");
    pub const audio = @import("lib/raylib/audio.kz");
    pub const physics = @import("lib/raylib/physics.kz");
};

// Usage: raylib.graphics.render.handler(...)
```

### Visibility Enforcement

The parser enforces public/private visibility:
- **Parse time**: Check if imported event has `~pub` marker
- **Error**: Emit parse error if accessing non-public event
- **No runtime cost**: Visibility is purely compile-time

---

## Design Rationale

**Why directory-based namespaces?**
- Natural organization (filesystem structure = code structure)
- Automatic collision prevention
- Scales to large codebases
- No manual namespace declarations

**Why two-level hierarchy?**
- Package groups related functionality
- Module provides fine-grained organization
- Prevents deeply nested namespaces
- Balances organization with usability

**Why explicit public markers?**
- Prevents accidental API exposure
- Clear API boundaries
- Enables refactoring without breaking imports
- Self-documenting code


---

## Cross-Module Type References

When an imported module defines Zig types (structs, enums, unions), you can reference them in event signatures using the `:` operator.

### Basic Type Reference

```koru
// In test_lib/user.kz
pub const User = struct {
    name: []const u8,
    age: u32,
};

~pub event create { name: []const u8, age: u32 }
| created { user: User }
```

```koru
// In main.kz
~import "test_lib"

// Reference the User type from the imported module
~pub event register_user {
    user_data: test_lib.user:User,  // module.submodule:Type
}
| registered { success: bool }
```

**Syntax**: `module.submodule:TypeName`

The `:` operator separates the module reference from the type name, consistent with event invocation syntax.

See: [162_cross_module_type_basic](162_cross_module_type_basic/)

### Type References with Aliases

Import aliases work for type references too:

```koru
~import "test_lib" => u

~pub event register_user {
    user_data: u.user:User,  // alias works for types
}
| registered { success: bool }
```

See: [163_cross_module_type_aliased](163_cross_module_type_aliased/)

### Nested Module Types

Types from nested directory structures use dotted paths:

```koru
// test_lib/domain/user.kz defines DomainUser
~import "test_lib"

~pub event grant_access {
    user_data: test_lib.domain.user:DomainUser,
}
| granted { success: bool }
```

See: [164_cross_module_type_nested](164_cross_module_type_nested/)

### Design Rationale

**Why use `:` for type references?**
- Consistent with event invocation: `module:event()` and `module:Type`
- Unambiguous parsing (`:` clearly separates module from type)
- Works with aliases naturally
- No conflict with Zig's `.` member access

**What types can be referenced?**
- Any `pub const` Zig type defined in an imported module
- Structs, enums, unions, type aliases
- The type must be `pub` to be accessible

**Code generation**:
The compiler generates proper Zig namespace references:
```zig
// For: test_lib.user:User
test_lib.user.User
```

---

## Related Specifications

- [Core Language - Events](../000_CORE_LANGUAGE/SPEC.md#event-declaration) - Event syntax
- [Core Language - Lexical Elements](../000_CORE_LANGUAGE/SPEC.md#identifiers) - Dotted identifiers
- [Taps & Observers - Module-Qualified Taps](../500_TAPS_OBSERVERS/SPEC.md#module-qualified-taps) - Observing imported events