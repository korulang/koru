#!/usr/bin/env bash
# Compile the commit-cadence instrument to the live one-tick binary `cc_live`,
# by transpiling model.wmfx THROUGH the WMFX engine and building cc_live.zig
# against the engine-emitted model. Run this at install time; the commit-msg
# hook invokes the resulting binary per commit.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="${WMFX_ENGINE:-$HOME/src/6digit-world}"
cd "$HERE"
( cd "$ENGINE" && zig build run -- --emit-zig "$HERE/model.wmfx" "$HERE/.model.zig" )
zig build-exe -OReleaseSafe --dep model -Mroot=cc_live.zig -Mmodel=.model.zig --name cc_live
rm -f .model.zig cc_live.o
echo "built: $HERE/cc_live"
