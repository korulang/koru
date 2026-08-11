#!/usr/bin/env bash
# Third pass. A Koru MODULE can span several files with the same stem and
# different extensions -- `helper.kz` declares the event, `helper.kjs` carries
# the |js proc body, and the import merges them (110_001_file_import_basic).
# `koruc --list-imports` names only ONE of them, so a symbol table built from
# its output can be missing the very declaration the call site needs.
# Dump every same-stem sibling of every import entry.
set -u
OUT="${1:?usage: dump_siblings.sh <outdir>}"
WORK="$OUT/work"; mkdir -p "$WORK"
hashpath() { printf '%s' "$1" | shasum -a 1 | cut -c1-40; }

: > "$WORK/allimports.txt"
for j in "$OUT"/imports/*.json; do
  python3 - "$j" >> "$WORK/allimports.txt" <<'PY' 2>/dev/null || true
import json,sys,os
try: a=json.load(open(sys.argv[1]))
except Exception: a=[]
if isinstance(a,list):
    for p in a:
        if isinstance(p,str) and os.path.isfile(p): print(p)
PY
done
# roots too: a root's own stem can have siblings
cat "$OUT/roots.txt" >> "$WORK/allimports.txt"
sort -u "$WORK/allimports.txt" > "$WORK/allimports_u.txt"
echo "import files: $(wc -l < "$WORK/allimports_u.txt")"

: > "$OUT/siblings.tsv"
n=0
while IFS= read -r f; do
  stem="${f%.*}"
  for ext in k kz kjs kgpu kc; do
    s="$stem.$ext"
    [ -f "$s" ] || continue
    [ "$s" = "$f" ] && continue
    h="$(hashpath "$s")"
    if [ ! -f "$OUT/ast/$h.json" ]; then
      ( cd "$WORK" && koruc --ast-canon "$s" >"$OUT/ast/$h.json" 2>"$OUT/ast/$h.err" )
      printf '%s\n' "$s" > "$OUT/ast/$h.path"
    fi
    printf '%s\t%s\n' "$f" "$s" >> "$OUT/siblings.tsv"
    n=$((n+1))
  done
done < "$WORK/allimports_u.txt"
echo "sibling files linked: $n"
