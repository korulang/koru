#!/usr/bin/env python3
"""
Rewrite redundant explicit labels in test corpus.

Mirrors `lexer.isRedundantExplicitLabel`: when a `name: value` pair has a
bare-identifier-path `value` whose last dot-separated segment matches `name`,
the label is redundant — drop it.

Examples:
  v: v               -> v
  x: p.x             -> p.x
  ast: c.ctx.ast     -> c.ctx.ast

Skips:
  - Lines starting with `//` (pure comment lines)
  - Matches that fall inside a `"..."` or `'...'` string literal on the line
  - Values that contain operators, parens, brackets, or `..` (per the helper)
"""
import pathlib
import re
import sys

PATTERN = re.compile(r'\b([a-z_][a-z_0-9]*): ([a-zA-Z_][a-zA-Z_0-9.]*)(?=\s*[,)}\n])')

def is_redundant(name: str, value: str) -> bool:
    if not value:
        return False
    if '..' in value:
        return False
    if value[0] == '.' or value[-1] == '.':
        return False
    if value[0].isdigit():
        return False
    last_seg = value.rsplit('.', 1)[-1]
    return last_seg == name

def fix_line(line: str) -> tuple[str, int]:
    stripped = line.lstrip()
    if stripped.startswith('//'):
        return line, 0
    out = []
    i = 0
    fixes = 0
    in_str = False
    str_char = None
    while i < len(line):
        c = line[i]
        if in_str:
            if c == '\\' and i + 1 < len(line):
                out.append(c)
                out.append(line[i + 1])
                i += 2
                continue
            if c == str_char:
                in_str = False
                str_char = None
            out.append(c)
            i += 1
            continue
        if c in ('"', "'"):
            in_str = True
            str_char = c
            out.append(c)
            i += 1
            continue
        m = PATTERN.match(line, i)
        if m:
            name, value = m.group(1), m.group(2)
            if is_redundant(name, value):
                out.append(value)
                i = m.end()
                fixes += 1
                continue
        out.append(c)
        i += 1
    return ''.join(out), fixes

def fix_file(path: pathlib.Path, write: bool) -> int:
    original = path.read_text()
    new_lines = []
    file_fixes = 0
    for line in original.splitlines(keepends=True):
        new_line, n = fix_line(line)
        new_lines.append(new_line)
        file_fixes += n
    if file_fixes > 0 and write:
        path.write_text(''.join(new_lines))
    return file_fixes

def main():
    write = '--write' in sys.argv
    target_arg = next((a for a in sys.argv[1:] if not a.startswith('--')), 'tests/regression')
    root = pathlib.Path(target_arg)
    total = 0
    files_changed = 0
    if root.is_file():
        n = fix_file(root, write)
        if n:
            print(f"{root}: {n}")
            total = n
            files_changed = 1
    else:
        # Skip the negative tests that intentionally contain the rejected form.
        EXCLUDED = {
            '210_088_reject_redundant_punning_call_site',
            '210_089_reject_redundant_punning_path',
            '210_090_reject_redundant_punning_constructor',
        }
        for p in sorted(root.rglob('*.kz')):
            if any(part in EXCLUDED for part in p.parts):
                continue
            n = fix_file(p, write)
            if n > 0:
                files_changed += 1
                total += n
                print(f"{p}: {n}")
    verb = "rewrote" if write else "would rewrite"
    print(f"\nTotal: {verb} {total} label(s) across {files_changed} file(s)")

if __name__ == '__main__':
    main()
