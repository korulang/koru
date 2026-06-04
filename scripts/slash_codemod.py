#!/usr/bin/env python3
"""
Slash codemod — module-path `.` -> `/` at call sites.

`/` is the one namespace separator. At a call site `std.io:print.ln`, the part
BEFORE the `:` pivot is a module path (its `.` -> `/`); the part AFTER stays
(member access, `print.ln`). Region-aware (skip `~proc {...}` Zig bodies) and
mask `{{ ... }}` interpolation spans (there `final.acc.count:d` is field-access
+ format-spec, NOT a module path).

Usage:
  slash_codemod.py --dry-run <files...>
  slash_codemod.py --apply   <files...>
"""
import re
import sys

PROC_RE = re.compile(r'^\s*~?(?:\[[^\]]*\])?\s*(?:pub\s+)?proc\b')
# A dotted lowercase module path immediately followed by the `:` pivot and a
# symbol char. Lookbehind avoids matching mid-identifier or after `/`/`.`.
PIVOT_RE = re.compile(r'(?<![\w/.])([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+):(?=[a-z_])')
INTERP_RE = re.compile(r'\{\{.*?\}\}')


def proc_body_mask(lines):
    mask = [False] * len(lines)
    i, n = 0, len(lines)
    while i < n:
        if not PROC_RE.match(lines[i]):
            i += 1
            continue
        j = i
        while j < n and '{' not in lines[j]:
            j += 1
        if j >= n:
            i += 1
            continue
        depth = lines[j].count('{') - lines[j].count('}')
        k = j + 1
        while k < n and depth > 0:
            mask[k] = True
            depth += lines[k].count('{') - lines[k].count('}')
            k += 1
        i = k
    return mask


def convert_line(line):
    # Blank out {{...}} spans so PIVOT_RE can't see inside them, then splice
    # converted text back around the preserved interpolation spans.
    spans = [(m.start(), m.end()) for m in INTERP_RE.finditer(line)]
    out = []
    pos = 0
    count = 0
    for s, e in spans + [(len(line), len(line))]:
        seg = line[pos:s]
        new, c = PIVOT_RE.subn(lambda m: m.group(1).replace('.', '/') + ':', seg)
        count += c
        out.append(new)
        if e <= len(line) and s != len(line):
            out.append(line[s:e])  # untouched interpolation span
        pos = e
    return ''.join(out), count


def transform(text):
    lines = text.split('\n')
    mask = proc_body_mask(lines)
    out = []
    total = 0
    for i, line in enumerate(lines):
        if mask[i]:
            out.append(line)
            continue
        new, c = convert_line(line)
        total += c
        out.append(new)
    return '\n'.join(out), total


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('--dry-run', '--apply'):
        print(__doc__)
        sys.exit(2)
    mode, files = sys.argv[1], sys.argv[2:]
    tf = tr = 0
    for p in files:
        try:
            with open(p) as f:
                text = f.read()
        except (IsADirectoryError, UnicodeDecodeError, FileNotFoundError):
            continue
        new, c = transform(text)
        if c == 0:
            continue
        tf += 1
        tr += c
        if mode == '--dry-run':
            print(f'{c:4d} repl  {p}')
        else:
            with open(p, 'w') as f:
                f.write(new)
    print(f'\n{"DRY-RUN" if mode=="--dry-run" else "APPLIED"}: {tr} replacements across {tf} files')


if __name__ == '__main__':
    main()
