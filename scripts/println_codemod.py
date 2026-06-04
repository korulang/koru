#!/usr/bin/env python3
"""
println -> print.ln codemod.

`std/io:println` is removed (it was a non-interpolating nerf of `print.ln`).
Every call `<ns>println(text: ARG)` becomes `<ns>print.ln(ARG)` — the `text:`
key is dropped and `print.ln` takes the value positionally (it accepts both a
bare expression `print.ln(s)` and an interpolated literal `print.ln("{{ x }}")`).

Scanning is balanced-paren + string-aware so a `(` or `)` inside the argument's
string literal (e.g. `println(text: "ok (done)")`) doesn't truncate the match.
Region-aware: `~proc {...}` host bodies are skipped (the `io.kz` definition and
host references stay as-is; the definition is deleted separately).

Usage:
  println_codemod.py --dry-run <files...>
  println_codemod.py --apply   <files...>
"""
import re
import sys

PROC_RE = re.compile(r'^\s*~?(?:\[[^\]]*\])?\s*(?:pub\s+)?proc\b')


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


def find_call_end(s, open_idx):
    """Given index of '(' in s, return index just past the matching ')',
    skipping over string literals. Returns -1 if unbalanced."""
    depth = 0
    i = open_idx
    in_str = False
    while i < len(s):
        c = s[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


TEXT_KEY = re.compile(r'^\s*text:\s*')
CALL = re.compile(r'(?<![\w.])println\(')


def convert_line(line):
    out = []
    pos = 0
    count = 0
    while True:
        m = CALL.search(line, pos)
        if not m:
            out.append(line[pos:])
            break
        open_idx = m.end() - 1  # the '('
        end = find_call_end(line, open_idx)
        if end == -1:
            out.append(line[pos:])
            break
        inner = line[open_idx + 1:end - 1]
        km = TEXT_KEY.match(inner)
        if not km:
            # Not the `text:` shape we expect — leave untouched, advance.
            out.append(line[pos:end])
            pos = end
            continue
        arg = inner[km.end():].rstrip()
        out.append(line[pos:m.start()])
        out.append('print.ln(' + arg + ')')
        count += 1
        pos = end
    return ''.join(out), count


def transform(text):
    # Negative tests that deliberately call the removed `println` opt out.
    if 'codemod:skip' in text:
        return text, 0
    lines = text.split('\n')
    mask = proc_body_mask(lines)
    out = []
    total = 0
    for i, line in enumerate(lines):
        if mask[i] or 'println(' not in line:
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
