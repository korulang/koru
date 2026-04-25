#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT="$ROOT/unity_dots"

UNITY="${UNITY:-}"
if [ -z "$UNITY" ]; then
  if command -v unity >/dev/null 2>&1; then
    UNITY="$(command -v unity)"
  elif [ -x "/Applications/Unity/Hub/Editor/6000.0.65f1/Unity.app/Contents/MacOS/Unity" ]; then
    UNITY="/Applications/Unity/Hub/Editor/6000.0.65f1/Unity.app/Contents/MacOS/Unity"
  else
    echo "Unity executable not found. Set UNITY=/path/to/Unity and rerun." >&2
    exit 1
  fi
fi

"$UNITY" \
  -batchmode \
  -quit \
  -projectPath "$PROJECT" \
  -executeMethod DotsArchetypeChurnBenchmark.Run \
  --entities 100000 \
  --frames 100

