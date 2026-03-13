# Unused Resources: Cleanup Is Not Correctness

## The Thesis

**Automatic cleanup (RAII, IDisposable, `use` statements) prevents resource leaks but not resource waste.**

Consider this Rust code:

```rust
let mut conn = Connection::open_in_memory().unwrap();
let _stmt = conn.prepare("SELECT 1").unwrap();
let tx = conn.transaction().unwrap();
```

All three resources are "safely" cleaned up when they go out of scope. Rust considers this correct. But:

- The connection was opened and never used for anything meaningful
- The statement was prepared but never executed  
- The transaction was started but never committed or rolled back

**This is a logic error.** The program does nothing while pretending to do database work.

## The Problem

| Language | Guarantee | Gap |
|----------|-----------|-----|
| Rust | Resources are dropped | Doesn't ensure they were *used* |
| F# | `IDisposable` is honored | Doesn't ensure meaningful work |
| C++ | Destructors run | Same gap |
| Go | `defer` executes | Same gap |

**Every language with automatic cleanup has this gap.** They track "must be cleaned up" but not "must be used meaningfully."

## The Koru Solution

Koru's phantom obligations express *semantic* requirements, not just cleanup:

```koru
~pub event connect { host: []const u8 }
| ok { conn: Connection[open!] }    // [open!] = obligation to USE this
```

The `[open!]` marker doesn't mean "must be closed" — it means "must be consumed by something that uses a connection." You satisfy it by calling `begin()` which *consumes* the connection to create a transaction.

Similarly:

```koru  
~pub event begin { conn: Connection[!open] }  // [!open] = consumes the obligation
| ok { tx: Transaction[active!] }              // [active!] = new obligation
```

The transaction obligation `[active!]` must be consumed by either `commit()` or `rollback()` — explicitly.

## Test Cases

### Negative Tests (Should Fail to Compile)

**01_unused_connection**: Open a connection, don't use it
```koru
~app.db:connect(host: "localhost")
| ok conn |>
    _  // ERROR: Connection[open!] not consumed
```

**02_uncommitted_transaction**: Start a transaction, don't end it
```koru
~app.db:connect(host: "localhost")
| ok conn |>
    app.db:begin(conn: conn.conn)
    | ok tx |>
        _  // ERROR: Transaction[active!] not consumed
```

### Positive Tests (Should Compile)

**03_valid_commit**: Full flow with commit
```koru
~app.db:connect(host: "localhost")
| ok conn |>
    app.db:begin(conn: conn.conn)
    | ok tx |>
        app.db:execute(tx: tx.tx, sql: "INSERT ...")
        | ok result |>
            app.db:commit(tx: result.tx)  // ✓ All obligations satisfied
```

**04_valid_rollback**: Explicit rollback also satisfies the obligation
```koru
~app.db:connect(host: "localhost")
| ok conn |>
    app.db:begin(conn: conn.conn)
    | ok tx |>
        app.db:rollback(tx: tx.tx)  // ✓ Explicit intent
```

## Why This Matters

### 1. Resource Waste Is Real Cost

Even "temporary" resource acquisition has cost:
- Connection pool slots are limited
- Network round-trips aren't free
- Memory allocation isn't free
- Database server tracks connections

### 2. Silent Rollback Hides Bugs

When a transaction drops without commit in Rust/F#, it silently rolls back. But was that the intent? Often it's a bug — the programmer forgot `tx.commit()`.

Koru requires explicit `commit()` OR explicit `rollback()`. No silent behavior.

### 3. Compile-Time vs Runtime

Rust/F# catch resource *leaks* at compile time (via ownership/IDisposable).
Koru catches resource *waste* at compile time (via phantom obligations).

## Running the Tests

```bash
# Run all unused resource tests
./run_regression.sh 2104_unused

# Run just the negative tests (should fail)
./run_regression.sh 01_unused_connection
./run_regression.sh 02_uncommitted_transaction

# Run the positive tests (should pass)
./run_regression.sh 03_valid_commit
./run_regression.sh 04_valid_rollback
```

## For Your Presentation

The live demo flow:

1. Show `rust/unused_connection.rs` — compiles, runs, does nothing useful
2. Show `koru/01_unused_connection/input.kz` — try to compile, get error
3. Ask audience: "Which behavior is correct?"
4. Show `koru/03_valid_commit/input.kz` — compiles because it actually *does* something
5. Thesis: "Cleanup is not the same as correctness"
