#!/usr/bin/env bash
# Second pass: --list-imports reports a DIRECTORY import as the directory path,
# not its files. Expand every such entry and dump the ASTs of the Koru files
# inside it, so a program's symbol table contains its own sibling modules.
set -u
OUT="${1:?usage: dump_dirs.sh <outdir>}"
WORK="$OUT/work"; mkdir -p "$WORK"

hashpath() { printf '%s' "$1" | shasum -a 1 | cut -c1-40; }

: > "$WORK/dirs.txt"
for j in "$OUT"/imports/*.json; do
  python3 - "$j" >> "$WORK/dirs.txt" <<'PY' 2>/dev/null || true
import json,sys,os
try:
    a=json.load(open(sys.argv[1]))
except Exception:
    a=[]
if isinstance(a,list):
    for p in a:
        if isinstance(p,str) and os.path.isdir(p):
            print(p)
PY
done
sort -u "$WORK/dirs.txt" > "$WORK/dirs_u.txt"
echo "directory imports: $(wc -l < "$WORK/dirs_u.txt")"

n=0
while IFS= read -r d; do
  [ -d "$d" ] || continue
  while IFS= read -r src; do
    h="$(hashpath "$src")"
    if [ ! -f "$OUT/ast/$h.json" ]; then
      ( cd "$WORK" && koruc --ast-canon "$src" >"$OUT/ast/$h.json" 2>"$OUT/ast/$h.err" )
      printf '%s\n' "$src" > "$OUT/ast/$h.path"
    fi
    printf '%s\t%s\n' "$d" "$src" >> "$OUT/dirmembers.tsv"
    n=$((n+1))
  done < <(find "$d" -type f \( -name '*.k' -o -name '*.kz' -o -name '*.kjs' -o -name '*.kgpu' -o -name '*.kc' \))
done < "$WORK/dirs_u.txt"
echo "expanded files: $n"
