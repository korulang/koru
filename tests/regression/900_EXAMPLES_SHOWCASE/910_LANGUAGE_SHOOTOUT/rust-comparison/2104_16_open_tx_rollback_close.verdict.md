# 2104_16_open_tx_rollback_close

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_16 2104_16_open_tx_rollback_close.rs

**rustc output:** compiled cleanly, no diagnostics (zero output, exit 0).

**Program output (`/tmp/rustcmp_16`):**

```
Executing: UPDATE inventory SET qty = 0
ROLLBACK
Connection closed
```

**Rust:** the `rollback` arm of the same typestate chain (`open -> begin -> exec -> rollback -> close`) compiles and runs, printing exactly the three expected lines — `rollback()` and `commit()` are twin methods on `Transaction<Active>`, both returning `Connection<Active>`, so the same explicit `close()` / `Drop` machinery from 2104_14 applies unchanged.

**Koru:** `MUST_RUN`, `expected.txt` is byte-identical to the three lines above — "Ground truth for korulang.org phantom explorer — exec then rollback & close."

**DIFFERS: no** — identical program behavior.
