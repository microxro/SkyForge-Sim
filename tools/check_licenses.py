#!/usr/bin/env python3
"""Licence/attribution gate: every SwiftPM dependency appears in THIRD_PARTY_NOTICES.md, every
network host referenced in Sources appears in docs/DATA_SOURCES.md, and no GPL/LGPL/AGPL text in Sources."""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent
errors = []
notices = (root / 'THIRD_PARTY_NOTICES.md').read_text()
for url in re.findall(r'\.package\(url: "([^"]+)"', (root / 'Packages/SkyforgeKit/Package.swift').read_text()):
    name = url.rstrip('/').split('/')[-1].removesuffix('.git')
    if name not in notices:
        errors.append(f'dependency {name} missing from THIRD_PARTY_NOTICES.md')
sources = root / 'Packages/SkyforgeKit/Sources'
data_sources = (root / 'docs/DATA_SOURCES.md').read_text()
for f in sources.rglob('*.swift'):
    t = f.read_text()
    for host in re.findall(r'https?://([A-Za-z0-9.-]+)', t):
        if host not in data_sources:
            errors.append(f'{f.relative_to(root)}: host {host} not in docs/DATA_SOURCES.md')
    if re.search(r'GNU (Lesser |Affero )?General Public License', t):
        errors.append(f'{f.relative_to(root)}: GPL-family licence text found')
for e in errors: print('licence check:', e)
print('licence check:', 'FAIL' if errors else 'OK')
sys.exit(1 if errors else 0)
