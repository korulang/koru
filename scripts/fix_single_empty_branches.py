#!/usr/bin/env python3
"""
Fix single-empty-branch violations in Koru test files.

This script migrates events with a single empty branch (e.g., `| done`)
to proper void events (0 branches), and updates procs/continuations accordingly.

Usage:
    python3 scripts/fix_single_empty_branches.py [path/to/dir_or_file]

Without arguments, it scans tests/regression/ and fixes all violations.
"""

import sys
import os
import re
import argparse
from pathlib import Path


def find_single_empty_branches(content):
    """
    Find event declarations that have exactly one empty branch.
    Returns list of (event_name, branch_name, line_number).
    """
    lines = content.split('\n')
    results = []
    i = 0
    while i < len(lines):
        line = lines[i]
        # Match event declaration start: ~[annotations] event name { ... }
        m = re.match(r'^(\s*~(?:\[.*?\])?\s*(?:pub\s+)?event\s+([\w.]+)\s*\{.*?)\s*$', line)
        if m:
            event_name = m.group(2)
            event_start = i
            branches = []
            i += 1
            # Collect branches until we hit a non-branch line
            while i < len(lines):
                branch_line = lines[i]
                stripped = branch_line.strip()
                # Branch line: | name or | name Type or | name { ... }
                if re.match(r'^\|\s*[&?]?\s*[\w_]+', stripped):
                    branch_match = re.match(r'^\|\s*[&?]?\s*([\w_]+)\s*(.*)$', stripped)
                    if branch_match:
                        branch_name = branch_match.group(1)
                        rest = branch_match.group(2).strip()
                        # Check if empty: no type, no braces
                        is_empty = not rest or rest.startswith('//')
                        branches.append({
                            'name': branch_name,
                            'line': i,
                            'is_empty': is_empty,
                            'line_text': branch_line,
                        })
                    i += 1
                elif stripped.startswith('~proc ') or stripped.startswith('~tap ') or stripped == '' or stripped.startswith('//'):
                    i += 1
                    continue
                else:
                    break

            if len(branches) == 1 and branches[0]['is_empty']:
                results.append({
                    'event_name': event_name,
                    'branch_name': branches[0]['name'],
                    'branch_line': branches[0]['line'],
                    'branch_text': branches[0]['line_text'],
                })
        i += 1
    return results


def fix_file(filepath, dry_run=False):
    """
    Fix single-empty-branch violations in a single .kz file.
    Returns (num_fixed, description).
    """
    content = filepath.read_text()
    original = content
    fixes = find_single_empty_branches(content)

    if not fixes:
        return 0, None

    lines = content.split('\n')
    fixed_count = 0
    descriptions = []

    for fix in fixes:
        event_name = fix['event_name']
        branch_name = fix['branch_name']
        branch_line_idx = fix['branch_line']

        # 1. Remove the branch line from event declaration
        lines[branch_line_idx] = None  # Mark for deletion

        # 2. Find and fix the proc body: remove `return .{ .branch = .{} };`
        # Look for proc implementing this event
        proc_pattern = re.compile(
            r'^(\s*~(?:\[.*?\])?\s*proc\s+' + re.escape(event_name) + r'\s*\{)'
        )
        for j, line in enumerate(lines):
            if line and proc_pattern.match(line):
                # Found the proc, now look for return statement in next ~30 lines
                for k in range(j + 1, min(j + 30, len(lines))):
                    if lines[k] is None:
                        continue
                    # Match: return .{ ."branch" = .{} }; or return .{ .branch = .{} };
                    ret_pattern = re.compile(
                        r'^(\s*)return\s+\.\{\s*\.\@?"?' + re.escape(branch_name) + r'"?\s*=\s*\.\{\}\s*\};?\s*$'
                    )
                    if ret_pattern.match(lines[k]):
                        lines[k] = None
                        break
                break

        descriptions.append(f"{event_name}: removed `| {branch_name}` branch")
        fixed_count += 1

    # Remove None lines
    new_lines = [l for l in lines if l is not None]
    new_content = '\n'.join(new_lines)

    if not dry_run:
        filepath.write_text(new_content)

    return fixed_count, '; '.join(descriptions)


def main():
    parser = argparse.ArgumentParser(description='Fix single-empty-branch violations in Koru tests')
    parser.add_argument('paths', nargs='*', help='Files or directories to fix')
    parser.add_argument('--dry-run', action='store_true', help='Show what would be fixed without modifying')
    args = parser.parse_args()

    paths = args.paths or ['tests/regression']

    total_fixed = 0
    total_files = 0

    for path_str in paths:
        path = Path(path_str)
        if path.is_file() and path.suffix == '.kz':
            files = [path]
        elif path.is_dir():
            files = list(path.rglob('*.kz'))
        else:
            continue

        for f in files:
            count, desc = fix_file(f, dry_run=args.dry_run)
            if count > 0:
                total_fixed += count
                total_files += 1
                action = "Would fix" if args.dry_run else "Fixed"
                print(f"  {action}: {f} ({count} event{'s' if count > 1 else ''}: {desc})")

    action = "Would fix" if args.dry_run else "Fixed"
    print(f"\n{action} {total_fixed} event(s) in {total_files} file(s)")


if __name__ == '__main__':
    main()
