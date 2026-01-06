# @korulang/sqlite3

SQLite3 bindings for [Koru](https://korulang.org) with phantom type obligations.

## Installation

```bash
koruc app.kz i
```

In your `app.kz`:
```koru
~std.package:requires.npm { "@korulang/sqlite3": "^0.0.1" }
```

## Requirements

- SQLite3 development libraries installed on your system
  - macOS: `brew install sqlite3` (usually pre-installed)
  - Ubuntu/Debian: `apt install libsqlite3-dev`
  - Fedora: `dnf install sqlite-devel`

## Usage

```koru
~import "$koru/sqlite"

// Open a database (in-memory or file)
~koru.sqlite:open(path: ":memory:")
| db d |>
    // Execute SQL
    koru.sqlite:exec(d.conn, "CREATE TABLE users (id INTEGER, name TEXT)")
    | ok c |>
        koru.sqlite:exec(c.conn, "INSERT INTO users VALUES (1, 'Alice')")
        | ok c2 |>
            // Query with prepared statements
            koru.sqlite:query(c2.conn, "SELECT * FROM users")
            | row r |>
                koru.sqlite:col.int(r.stmt, 0)
                | value v |>
                    koru.sqlite:col.text(v.stmt, 1)
                    | value t |>
                        // Use t.text here (borrowed from statement)
                        koru.sqlite:next(r.conn, t.stmt)
                        | done conn |>
                            koru.sqlite:close(conn.conn)
                            | closed |> _
            | empty c3 |>
                koru.sqlite:close(c3.conn)
                | closed |> _
| err e |> _
```

## API

### Connection Management

- `open { path: []const u8 }` - Open database, returns `| db { conn[opened!] }` or `| err`
- `close { conn[!opened] }` - Close connection, returns `| closed`

### Query Execution

- `exec { conn[opened!], sql }` - Execute SQL without results, returns `| ok { conn }` or `| err`
- `query { conn[opened!], sql }` - Prepare and step, returns `| row { conn, stmt[prepared!] }`, `| empty`, or `| err`
- `next { conn[opened!], stmt[prepared!] }` - Get next row, returns `| row`, `| done`, or `| err`

### Column Access

- `col.int { stmt[prepared!], index }` - Get integer column
- `col.text { stmt[prepared!], index }` - Get text column (borrowed pointer, valid until next step)
- `col.real { stmt[prepared!], index }` - Get float column

## Phantom Types

This library uses Koru's phantom type system for compile-time safety:

- `Connection[opened!]` - Connection is open, must be closed
- `Statement[prepared!]` - Statement is prepared, will be auto-finalized

The compiler ensures you can't use a closed connection or forget to close an open one.

## License

MIT
