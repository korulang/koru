#!/bin/bash
# Bare-stem command dispatch must match explicit-facet dispatch byte-for-byte.
set -e

# 1. Bare stem dispatches the shell command (no full build, no fall-through).
stem_hello="$(koruc input hello)"
facet_hello="$(koruc "$KORU_INPUT" hello)"
if [ "$stem_hello" != "$facet_hello" ]; then
  echo "FAIL: 'koruc input hello' != 'koruc $KORU_INPUT hello'"
  echo "  stem : $stem_hello"
  echo "  facet: $facet_hello"
  exit 1
fi
if [ "$stem_hello" != "Hello from Koru!" ]; then
  echo "FAIL: expected 'Hello from Koru!', got: $stem_hello"
  exit 1
fi

# 2. Trailing args pass through the bare-stem form identically.
stem_args="$(koruc input args one two three)"
facet_args="$(koruc "$KORU_INPUT" args one two three)"
if [ "$stem_args" != "$facet_args" ]; then
  echo "FAIL: trailing args differ between stem and facet"
  echo "  stem : $stem_args"
  echo "  facet: $facet_args"
  exit 1
fi
if [ "$stem_args" != "Args: one two three" ]; then
  echo "FAIL: expected 'Args: one two three', got: $stem_args"
  exit 1
fi

echo "OK: bare-stem command dispatch matches explicit facet"
