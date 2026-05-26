#!/usr/bin/env bash
# Aggregate results.csv files into a markdown table
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/results"

for f in *.csv; do
    WL="${f%.csv}"
    echo "## $WL"
    echo ""
    echo "| n | Koru | Rust | C# | JS | Python |"
    echo "|---|------|------|------|------|--------|"
    for N in 1000000 10000000 100000000 1000000000; do
        ROW="| $N "
        for LANG in koru rust csharp javascript python; do
            MS=$(awk -F, -v w="$WL" -v l="$LANG" -v n="$N" '$1==w && $2==l && $3==n {print $4}' "$f")
            ROW="$ROW| ${MS:-—} "
        done
        echo "$ROW|"
    done
    echo ""
done
