# Gauntlet (moved)

The Cordis parity gauntlet — ledger, verdict, cross-language closer — lives in
the **KOPIUM** repo, not here:

**`/Users/larsde/src/kopium/gauntlet/cordis/`**

Regression pins stay in this repo under
`tests/regression/400_RUNTIME_FEATURES/440_RESOURCE_BRIDGE/` (`440_010`–`440_016`).
The closer invokes `./run_single_test.sh` against those paths; run it from kopium:

```bash
cd /Users/larsde/src/kopium
node gauntlet/cordis/crosslang/closer.mjs
```
