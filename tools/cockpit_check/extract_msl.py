#!/usr/bin/env python3
"""Pulls the MSL out of CockpitMaterialShaders.swift for the host-side checks (float literals get an f suffix,
as MSL's are single precision). Usage: extract_msl.py <swift file> <out dir>"""
import re, sys, os
src = open(sys.argv[1]).read()
out = sys.argv[2]
body = src[src.index('"""\n') + 4: src.rindex('\n    """')]
body = body.replace('#include <metal_stdlib>\n', '').replace('using namespace metal;\n', '')
body = re.sub(r'(?<![\w.])(\d+\.\d*|\.\d+)(e[-+]?\d+)?(?![\w.])', lambda m: m.group(0) + 'f', body)
cut = body.rfind('// ====', 0, body.index('// Part 2: glue'))
os.makedirs(out, exist_ok=True)
open(os.path.join(out, 'part1.cpp'), 'w').write('#include "metal_shim.h"\n' + body[:cut])
open(os.path.join(out, 'full.cpp'), 'w').write('#include "metal_shim.h"\n#include "stubs.h"\n' + body)
