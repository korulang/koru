#!/bin/bash
# Generate a standalone parser from this grammar in BOTH backends, build each
# with the host toolchain, and check every oracle case — values and error
# positions alike.
#
# `zig cc` builds the C backend on purpose: zig is already a hard dependency of
# the suite, so pinning the C emitter costs no new toolchain.
#
# The oracle is INLINE rather than a sibling file: tests/regression/.gitignore
# ignores everything not explicitly negated, so a .tsv beside this script would
# never reach a fresh clone and the pin would quietly stop asserting anything.
set -u
fails=0

printf '42\tOK: 42\n'                                                  >  oracle.tmp
printf '[[[123]]]\tOK: 123\n'                                          >> oracle.tmp
printf -- '-17\tOK: -17\n'                                             >> oracle.tmp
printf '[42\tPARSE-ERROR 1:4 expected ] found end of input\n'          >> oracle.tmp
printf 'abc\tPARSE-ERROR 1:1 expected -?[0-9]+ found a\n'              >> oracle.tmp
printf '[1,2]\tPARSE-ERROR 1:3 expected ] found ,\n'                   >> oracle.tmp
printf '[]\tPARSE-ERROR 1:2 expected -?[0-9]+ found ]\n'               >> oracle.tmp

check_backend() {
  local lang="$1" ext="$2" bin="run_$1"
  if ! koruc "$KORU_INPUT" parser:generate "$lang" > "gen_$lang.log" 2>&1; then
    echo "FAIL($lang): parser:generate did not emit — see gen_$lang.log"; return 1
  fi
  local src="nums.$ext"
  [ -f "$src" ] || { echo "FAIL($lang): no emitted $src"; return 1; }

  case "$lang" in
    c)   zig cc -O2 -o "$bin" "$src" 2>"build_$lang.err" ;;
    zig) zig build-exe -O ReleaseFast --name "$bin" "$src" 2>"build_$lang.err" ;;
  esac
  [ -x "$bin" ] || { echo "FAIL($lang): emitted source did not build"; sed -n '1,5p' "build_$lang.err"; return 1; }

  local n=0 ok=0
  while IFS=$'\t' read -r input want; do
    n=$((n+1))
    got="$(./"$bin" "$input" 2>&1)"
    if [ "$got" = "$want" ]; then ok=$((ok+1))
    else echo "FAIL($lang): in=[$input] want=[$want] got=[$got]"; fi
  done < oracle.tmp
  echo "$lang: $ok/$n oracle cases matched"
  [ "$ok" = "$n" ]
}

check_backend c   c   || fails=1
check_backend zig zig || fails=1

if [ "$fails" = 0 ]; then
  # Clean up ONLY on success. The emitted parsers are generated artifacts, not
  # sources — and tests/regression/.gitignore un-ignores **/*.c, so leaving
  # nums.c behind would commit generated output as if it were hand-written.
  # On failure they stay put, because that is exactly when you need to read them.
  rm -f nums.c nums.zig run_c run_zig gen_c.log gen_zig.log build_c.err build_zig.err oracle.tmp
  rm -rf .zig-cache zig-out
  echo "PASS: generate conforms on both backends"; exit 0
fi
echo "FAIL: generate did not conform (artifacts kept for diagnosis)"; exit 1
