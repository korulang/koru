#!/bin/bash
# Pins both fixes. Runs against the REAL koruc via PATH + $KORU_INPUT.
set -e

# Fix 1: a kebab-named [comptime|command] must compile AND dispatch a valid
# handler symbol (module emitter mangles, dispatcher must too).
kebab_out="$(koruc "$KORU_INPUT" publish-npm 2>&1)"
case "$kebab_out" in
  *"kebab command ran"*) ;;
  *) echo "FAIL: kebab-named command did not dispatch cleanly"; echo "  got: $kebab_out"; exit 1;;
esac

# Fix 2: `ci` drives the step graph in depends_on (topological) order — build
# declared LAST but must run FIRST because release depends_on build.
ci_out="$(koruc "$KORU_INPUT" ci 2>&1)"
build_pos="$(echo "$ci_out" | grep -n 'build step' | head -1 | cut -d: -f1)"
release_pos="$(echo "$ci_out" | grep -n 'release step' | head -1 | cut -d: -f1)"
if [ -z "$build_pos" ] || [ -z "$release_pos" ]; then
  echo "FAIL: ci did not run both steps"; echo "  got: $ci_out"; exit 1
fi
if [ "$build_pos" -ge "$release_pos" ]; then
  echo "FAIL: ci ran in declaration order, not dependency order"
  echo "  build at $build_pos, release at $release_pos"
  exit 1
fi

echo "OK: kebab command symbol + ci step-graph driving"
