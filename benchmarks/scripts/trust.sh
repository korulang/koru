#!/usr/bin/env bash
# trust.sh <workload> <n> [lang ...]  — trustworthy kernel microbenchmark runner.
#
# Trust failures it exists to prevent (all measured, 2026-08-28):
#   - wall-clock is corruptible by co-tenants and by thermal throttle. A long
#     reduce loop heats the die, later runs throttle, the median is dragged up
#     while the cool min is the true cost. Wall once fabricated a "44% behind C"
#     gap; user-CPU time shows parity (reduce_kernel README).
#   - run.sh's python3 timing wrapper adds 30-50 ms of its own wall.
#   - one median is not a measurement; a numeric result without a spread flag
#     cannot tell you it is untrustworthy.
#
# Protocol, therefore:
#   - measure USER-CPU seconds (/usr/bin/time -p) — immune to co-tenants and to
#     frequency/thermal drift for a CPU-bound loop;
#   - quiet-gate as a WARNING (user-time does not need a quiet machine, but a
#     busy one widens the spread and the number should say so);
#   - interleave languages across rounds so all see the same machine profile;
#   - report min (best, unthrottled) AND median, plus the spread between them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WL="$1"; N="$2"; shift 2
ROUNDS="${ROUNDS:-3}"; RUNS="${RUNS:-4}"
[ "$#" -ge 1 ] || { echo "usage: trust.sh <workload> <n> <lang...>"; exit 2; }

CORES=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc)
LOAD=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
BUSY="-"
if [ -n "${LOAD:-}" ]; then
    if python3 -c "import sys; sys.exit(0 if float('$LOAD') > float('$CORES')*0.8 else 1)" 2>/dev/null; then
        BUSY="BUSY (load $LOAD / $CORES) — spread will be wide"
    fi
fi

lang_cmd() {
    case "$1" in
        koru) echo "$ROOT/workloads/$WL/koru/a.out" ;;
        c)    echo "$ROOT/workloads/$WL/c/bench" ;;
        rust) echo "$ROOT/workloads/$WL/rust/target/release/bench" ;;
        *)    echo "trust.sh: unknown lang $1" >&2; exit 2 ;;
    esac
}
work_elem() {
    case "$WL" in
        reduce_kernel) echo $((64 * N)) ;;
        *)             echo "$N" ;;
    esac
}
WORK="$(work_elem)"

echo "## $WL  n=$N  (${ROUNDS} rounds x ${RUNS} runs, user-CPU seconds)"
printf "%-8s %-8s %-8s\n" language ns_elem_min ns_elem_median spread
for lang in "$@"; do
    CMD="$(lang_cmd "$lang")"
    ud=()
    for r in $(seq 1 "$ROUNDS"); do
        for i in $(seq 1 "$RUNS"); do
            U=$(/usr/bin/time -p "$CMD" "$N" 2>&1 1>/dev/null \
                 | grep -E '^user ' | awk '{print $2}' | tail -1)
            # /usr/bin/time prints "user <sec>" even on a failed child, but a
            # heavily loaded machine can kill the process mid-run and suppress
            # the line. A missing sample is a missing sample, not a zero — skip.
            if [ -n "$U" ]; then ud+=("$U"); fi
        done
    done
    # sort; report min and median (user is already robust, so median is meaningful)
    if [ "${#ud[@]}" -eq 0 ]; then
        printf "%-8s %-8s %-8s %-8s\n" "$lang" "n/a" "n/a" "n/a"
        continue
    fi
    SORTED=$(printf '%s\n' "${ud[@]}" | sort -n)
    MIN=$(echo "$SORTED" | head -1)
    MED=$(echo "$SORTED" | awk '{a[NR]=$1} END{ if (NR==0) exit; if (NR%2) print a[(NR+1)/2]; else print (a[NR/2]+a[NR/2+1])/2 }')
    MINS=$(python3 -c "print('%.3f' % (float('$MIN')*1e9/$WORK))")
    MEDS=$(python3 -c "print('%.3f' % (float('$MED')*1e9/$WORK))")
    SPREAD=$(python3 -c "print('%.0f%%' % (100*abs(float('$MIN')-float('$MED'))/float('$MED')))")
    printf "%-8s %-8s %-8s %-8s\n" "$lang" "$MINS" "$MEDS" "$SPREAD"
done
[ "$BUSY" = "-" ] || echo "note: $BUSY"
