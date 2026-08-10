# 2104_14_open_tx_commit_close

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_14 2104_14_open_tx_commit_close.rs

**rustc output:** compiled cleanly, no diagnostics (zero output, exit 0).

**Program output (`/tmp/rustcmp_14`):**

```
Executing: INSERT INTO users VALUES (1, 'alice')
COMMIT
Connection closed
```

**Rust:** the typestate chain `open -> begin -> exec -> commit -> close` compiles and, when run, prints exactly the three expected lines; `close()`'s entire body is empty — the "Connection closed" line comes from a `Drop` impl on `Connection<Active>` that fires when `close()`'s consumed `self` goes out of scope at the end of the function.

**Koru:** `MUST_RUN`, `expected.txt` is byte-identical to the three lines above — "Ground truth for korulang.org phantom explorer — happy commit & close."

**DIFFERS: no** — identical program behavior; worth noting Rust hit a real language limitation while building this file (`Drop` cannot be specialized for one type-parameter instantiation, rustc `E0366`), resolved with the idiomatic trait-with-default-override pattern (`OnDrop`), not a workaround around the comparison.
