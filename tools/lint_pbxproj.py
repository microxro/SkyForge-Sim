#!/usr/bin/env python3
"""Sanity-check a hand-written project.pbxproj on Linux (no plutil needed).
Checks: balanced braces/parens, unique 24-hex object IDs, every referenced ID defined, rootObject defined,
isa present for each object, objectVersion. Exit 1 on failure."""
import re, sys

def main(path):
    text = open(path, encoding='utf-8').read()
    errors = []
    if not text.startswith('// !$*UTF8*$!'):
        errors.append('missing UTF8 header')
    body = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    body = re.sub(r'"(?:[^"\\]|\\.)*"', '""', body)
    for o, c in ('{}', '()'):
        if body.count(o) != body.count(c):
            errors.append(f'unbalanced {o}{c}: {body.count(o)} vs {body.count(c)}')
    m = re.search(r'objects = \{(.*)\n\t\};\n\trootObject', text, flags=re.S)
    if not m:
        errors.append('objects section not found'); return report(errors)
    defs = re.findall(r'^\t\t([0-9A-Za-z]{24}) (?:/\*.*?\*/ )?= \{', m.group(1), flags=re.M)
    seen = set()
    for d in defs:
        if not re.fullmatch(r'[0-9A-F]{24}', d):
            errors.append(f'ID not 24 uppercase hex: {d}')
        if d in seen:
            errors.append(f'duplicate ID {d}')
        seen.add(d)
    refs = set(re.findall(r'\b([0-9A-F]{24})\b', text))
    for r in sorted(refs - seen):
        errors.append(f'referenced but undefined: {r}')
    root = re.search(r'rootObject = ([0-9A-F]{24})', text)
    if not root or root.group(1) not in seen:
        errors.append('rootObject undefined')
    nisa = len(re.findall(r'\bisa = ', m.group(1)))
    if nisa != len(defs):
        errors.append(f'isa count {nisa} != object count {len(defs)}')
    if 'objectVersion = 77;' not in text:
        errors.append('objectVersion is not 77')
    return report(errors, len(defs))

def report(errors, n=0):
    if errors:
        for e in errors: print('pbxproj lint:', e)
        return 1
    print(f'pbxproj lint: OK ({n} objects)')
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'SKYFORGE.xcodeproj/project.pbxproj'))
