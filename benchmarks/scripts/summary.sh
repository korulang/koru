#!/usr/bin/env bash
# Aggregate results/*.csv into markdown tables.
#
# The axes are DERIVED FROM THE DATA. They used to be hardcoded — the sizes as
# four powers of ten, the languages as a fixed five — and anything measured off
# that grid was rendered as an em-dash, which reads "not measured" when the
# number was sitting in the CSV. Four of nine workloads printed as entirely
# empty tables that way, including regex_match, whose Koru-vs-Rust numbers are
# the strongest claim in STATUS.md. Go was measured for three workloads and had
# no column at all.
#
# Repeats collapse to a MEDIAN (the discipline README.md already states) and say
# how many runs are behind them. Previously awk printed every matching row, so a
# repeated measurement emitted several numbers separated by newlines INTO one
# table cell, which breaks the markdown row outright.
#
# Rows with an empty wall_ms are skipped: that is what run.sh writes for a
# `run-failed` row, and a failure is not a measurement.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/results"

pretty() {
    case "$1" in
        koru)       echo "Koru" ;;
        rust)       echo "Rust" ;;
        csharp)     echo "C#" ;;
        javascript) echo "JS" ;;
        python)     echo "Python" ;;
        go)         echo "Go" ;;
        *)          echo "$1" ;;
    esac
}

for f in *.csv; do
    WL="${f%.csv}"
    echo "## $WL"
    echo ""

    MEASURED=$(awk -F, -v w="$WL" '$1==w && $4!="" {print $2}' "$f" | sort -u)
    # Koru leads — the table exists to compare against it — then the rest
    # alphabetically. Which languages appear is derived; only the order is a choice.
    LANGS=""
    for L in $MEASURED; do [ "$L" = koru ] && LANGS="koru"; done
    for L in $MEASURED; do [ "$L" = koru ] || LANGS="$LANGS $L"; done
    SIZES=$(awk -F, -v w="$WL" '$1==w && $4!="" {print $3}' "$f" | sort -n -u)

    if [ -z "$LANGS" ] || [ -z "$SIZES" ]; then
        # Say it plainly. An empty grid of dashes looks like a measurement too.
        echo "_No measurements recorded._"
        echo ""
        continue
    fi

    HEADER="| n "
    RULE="|---"
    for LANG in $LANGS; do
        HEADER="$HEADER| $(pretty "$LANG") "
        RULE="$RULE|------"
    done
    echo "$HEADER|"
    echo "$RULE|"

    for N in $SIZES; do
        ROW="| $N "
        for LANG in $LANGS; do
            CELL=$(awk -F, -v w="$WL" -v l="$LANG" -v n="$N" \
                       '$1==w && $2==l && $3==n && $4!="" {print $4}' "$f" \
                   | sort -n \
                   | awk '{a[NR]=$1}
                          END{ if (NR==0) exit
                               if (NR%2) m=a[(NR+1)/2]; else m=(a[NR/2]+a[NR/2+1])/2
                               if (NR>1) printf "%.3f ×%d", m, NR; else printf "%s", m }')
            ROW="$ROW| ${CELL:-—} "
        done
        echo "$ROW|"
    done
    echo ""
done
