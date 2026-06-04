#!/usr/bin/env python3
"""
Revert field/arg KEYS from kebab back to snake — keeping NAMES (event/proc/branch)
kebab. The design split: NAMES (the "verbs"/outcomes) read well kebab
(`~event delete`, `| not-found`); PROPERTIES (field/arg keys) read badly kebab
(`expected-x: i32`) and go snake (`expected_x: i32`).

Only the KEY position is touched — a kebab token immediately before a `:` (not
`::`), outside host code (`~proc {}` bodies + host decls) and outside string
literals. Names/branches (followed by `{`/`(`/space, never `:`) and qualifiers
are left kebab. Member-access keys (`obj.name:`) are excluded by the lookbehind.

Files marked `codemod:skip` (negative-test pins holding a deliberate spelling)
are left alone.

Usage:
  dekebab_keys.py --dry-run <files...>
  dekebab_keys.py --apply   <files...>
"""
import re
import sys
import kebab_codemod as kc

# A kebab identifier in KEY position: word-glued `-`, immediately before `:`
# (not `::`). Lookbehind excludes mid-identifier, slash/dot members, and `-`.
KEY = re.compile(r'(?<![\w/.-])([a-z][a-z0-9]*(?:-[a-z0-9]+)+)(?=\s*:(?!:))')


def comment_start(line, spans):
    """Index of the first `//` line-comment that is NOT inside a string span,
    or -1. Comment prose (`// backend-agnostic: ...`, bullet lists, example
    snippets) is NOT code and must not be reverted — only key positions in
    live Koru are touched."""
    idx = line.find('//')
    while idx != -1:
        if not any(s <= idx < e for s, e in spans):
            return idx
        idx = line.find('//', idx + 2)
    return -1


def revert_outside_strings(line):
    """Revert kebab keys -> snake in `line`, skipping double-quoted strings AND
    the trailing `//` comment (prose, not code)."""
    spans = [(m.start(), m.end()) for m in kc.STRING_RE.finditer(line)]
    cs = comment_start(line, spans)
    if cs == -1:
        head, tail = line, ''
    else:
        head, tail = line[:cs], line[cs:]
        spans = [(s, e) for s, e in spans if e <= cs]  # strings before the comment
    out = []
    pos = 0
    count = 0
    for s, e in spans + [(len(head), len(head))]:
        seg = head[pos:s]
        new, c = KEY.subn(lambda m: m.group(1).replace('-', '_'), seg)
        count += c
        out.append(new)
        if s != len(head):
            out.append(head[s:e])  # untouched string span
        pos = e
    return ''.join(out) + tail, count


def transform(text):
    if kc.should_skip(text):
        return text, 0
    lines = text.split('\n')
    mask = kc.host_mask(lines)
    out = []
    total = 0
    for i, line in enumerate(lines):
        if mask[i]:
            out.append(line)
            continue
        new, c = revert_outside_strings(line)
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
