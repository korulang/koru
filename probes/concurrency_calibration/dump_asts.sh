#!/usr/bin/env bash
# Dump --ast-canon JSON + --list-imports for every regression test root.
# Cache is keyed on the absolute source path, so koru_std modules are parsed once.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: dump_asts.sh <outdir>}"
mkdir -p "$OUT/ast" "$OUT/imports"
WORK="$OUT/work"
mkdir -p "$WORK"

hashpath() { printf '%s' "$1" | shasum -a 1 | cut -c1-40; }

dump_one() {
  local src="$1"
  local h; h="$(hashpath "$src")"
  if [ ! -f "$OUT/ast/$h.json" ]; then
    ( cd "$WORK" && koruc --ast-canon "$src" >"$OUT/ast/$h.json" 2>"$OUT/ast/$h.err" )
    printf '%s\n' "$src" > "$OUT/ast/$h.path"
  fi
}

# 1. enumerate roots
find "$ROOT/tests/regression" \( -name MUST_RUN -o -name MUST_ERROR \) -print \
  | sed 's|/[^/]*$||' | sort -u > "$OUT/testdirs.txt"

: > "$OUT/roots.txt"
while IFS= read -r d; do
  for ext in k kz kjs kgpu kc; do
    [ -f "$d/input.$ext" ] && printf '%s\n' "$d/input.$ext" >> "$OUT/roots.txt"
  done
done < "$OUT/testdirs.txt"

echo "roots: $(wc -l < "$OUT/roots.txt")"

# 2. imports + asts
n=0
while IFS= read -r src; do
  n=$((n+1))
  h="$(hashpath "$src")"
  if [ ! -f "$OUT/imports/$h.json" ]; then
    ( cd "$WORK" && koruc --list-imports "$src" >"$OUT/imports/$h.json" 2>"$OUT/imports/$h.err" )
    printf '%s\n' "$src" > "$OUT/imports/$h.path"
  fi
  dump_one "$src"
  # transitive modules
  python3 - "$OUT/imports/$h.json" <<'PY' > "$WORK/mods.txt" 2>/dev/null || : > "$WORK/mods.txt"
import json,sys
try:
    a=json.load(open(sys.argv[1]))
    if isinstance(a,list):
        for p in a: print(p)
except Exception:
    pass
PY
  while IFS= read -r m; do
    [ -n "$m" ] && [ -f "$m" ] && dump_one "$m"
  done < "$WORK/mods.txt"
  if [ $((n % 100)) -eq 0 ]; then echo "  ...$n"; fi
done < "$OUT/roots.txt"
echo "done: $n roots, $(ls "$OUT/ast"/*.json 2>/dev/null | wc -l) asts"
