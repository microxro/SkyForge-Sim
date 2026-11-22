#!/bin/sh
# Syntax-checks the cockpit MSL on any machine with clang++ and runs the anisotropic-GGX numeric checks.
set -e
cd "$(dirname "$0")"
OUT=$(mktemp -d "${TMPDIR:-/tmp}/cockpit_check.XXXXXX")
trap 'rm -rf "$OUT"' EXIT
python3 extract_msl.py ../../Packages/SkyforgeKit/Sources/SFRender/Shaders/CockpitMaterialShaders.swift "$OUT"
cp metal_shim.h stubs.h aniso_check.cpp "$OUT"/
cd "$OUT"
clang++ -std=c++17 -fsyntax-only -x c++ -Wno-unknown-attributes -Wall -Wno-unused full.cpp
clang++ -std=c++17 -O2 -Wno-unknown-attributes -Wno-unused -o aniso_check aniso_check.cpp
./aniso_check
