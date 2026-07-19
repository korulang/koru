#!/usr/bin/env bash
# Backend Bakeoff — conformance runner.
#
#   ./run.sh <lang>        grade the <lang> backend against every fixture
#   ./run.sh <lang> <grammar>   grade a single grammar
#
# For each grammar fixture it: emits the parser in <lang> via the toolchain
# (`koruc <grammar>.k parser:generate <lang>`), builds it with that language's
# NATIVE toolchain, runs every case, and diffs the output byte-for-byte against
# the pinned oracle (expected/<grammar>). The oracle is the Koru-faithful C
# reference (C conformance to Koru-native parse is verified). A backend passes
# only if EVERY case matches.
#
# To add a language: implement its recipe in `recipe()` below (emit extension +
# build command producing ./bin + run command). Everything else is target-blind.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KORUC="$HERE/../../zig-out/bin/koruc"
LANG_="${1:?usage: run.sh <lang> [grammar]}"
ONLY_GRAMMAR="${2:-}"
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; NC=$'\033[0m'

# recipe <lang>: sets EXT (emitted file extension), then BUILD and RUN are
# functions using $SRC (emitted file) and producing/using ./run_bin.
recipe() {
  case "$1" in
    c)
      EXT=c
      build() { cc -O2 -o run_bin "$SRC" 2>build.err; }
      run()   { ./run_bin "$1"; }
      ;;
    zig)
      EXT=zig
      build() { zig build-exe -O ReleaseFast --name run_bin "$SRC" 2>build.err; }
      run()   { ./run_bin "$1"; }
      ;;
    js)
      EXT=js
      build() { :; }                    # interpreted, no build
      run()   { node "$SRC" "$1"; }
      ;;
    python|py)
      EXT=py
      build() { :; }
      run()   { python3 "$SRC" "$1"; }
      ;;
    go)
      EXT=go
      build() { go build -o run_bin "$SRC" 2>build.err; }
      run()   { ./run_bin "$1"; }
      ;;
    rust|rs)
      EXT=rs
      build() { rustc -O -o run_bin "$SRC" 2>build.err; }
      run()   { ./run_bin "$1"; }
      ;;
    haskell|hs)
      EXT=hs
      build() { ghc -O2 -o run_bin "$SRC" 2>build.err; }
      run()   { ./run_bin "$1"; }
      ;;
    *)
      echo "${RED}no recipe for '$1' — add one in run.sh recipe()${NC}"; exit 2;;
  esac
}

recipe "$LANG_"
total=0; passed=0; fail_lines=()
for gpath in "$HERE"/grammars/*.k; do
  g="$(basename "$gpath" .k)"
  [ -n "$ONLY_GRAMMAR" ] && [ "$g" != "$ONLY_GRAMMAR" ] && continue
  [ -f "$HERE/expected/$g" ] || { echo "no oracle for $g — skip"; continue; }
  work="$HERE/work/$LANG_/$g"; rm -rf "$work"; mkdir -p "$work"; cp "$gpath" "$work/"
  ( cd "$work"
    if ! "$KORUC" "$g.k" parser:generate "$LANG_" >emit.log 2>&1; then
      echo "${RED}EMIT FAILED${NC} ($g/$LANG_) — see $work/emit.log"; exit 3
    fi
    SRC="$g.$EXT"
    [ -f "$SRC" ] || { echo "${RED}NO EMITTED FILE${NC} $SRC ($g/$LANG_)"; exit 3; }
    if ! build; then echo "${RED}BUILD FAILED${NC} ($g/$LANG_) — see $work/build.err"; exit 4; fi
  ) || continue
  # run every case, diff vs oracle
  while IFS=$'\t' read -r input expected; do
    total=$((total+1))
    got="$( cd "$work"; SRC="$g.$EXT"; recipe "$LANG_" >/dev/null 2>&1; run "$input" 2>&1 )"
    if [ "$got" = "$expected" ]; then passed=$((passed+1));
    else fail_lines+=("  $g  in=[$input]  want=[$expected]  got=[$got]"); fi
  done < "$HERE/expected/$g"
done

echo "════════════════════════════════════════"
if [ "${#fail_lines[@]}" -eq 0 ] && [ "$total" -gt 0 ]; then
  echo "${GRN}CONFORMANCE PASS${NC}: $LANG_ — $passed/$total cases match the oracle"
  exit 0
else
  echo "${RED}CONFORMANCE FAIL${NC}: $LANG_ — $passed/$total matched"
  printf '%s\n' "${fail_lines[@]}"
  exit 1
fi
