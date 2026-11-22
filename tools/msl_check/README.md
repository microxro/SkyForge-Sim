# msl_check: syntax harness for the Metal shaders embedded in Swift

```
python3 tools/msl_check/check_msl.py                                  # baseline: CloudShaders.common + WorldShaders.source
python3 tools/msl_check/check_msl.py AirportSurfaceShaders.swift ...  # baseline + each file's `source` literal
python3 tools/msl_check/check_msl.py Foo.swift:snippet                # a literal other than `source`
python3 tools/msl_check/check_msl.py --only Foo.swift                 # without the baseline
python3 tools/msl_check/check_msl.py --before MacroColourShaders.swift   # a library part that precedes WorldShaders (the order WorldRenderer builds)
python3 tools/msl_check/check_msl.py --dump /tmp/tu.cpp               # keep the translation unit
```

Needs `clang++` and Python 3. Bare file names are looked up in `Packages/SkyforgeKit/Sources/SFRender/Shaders`.
Diagnostics carry the Swift file and line (`#line` maps them).
`msl_shim.h` is generated: edit `gen_shim.py`, then run it.

## What it does

`check_msl.py` pulls each `public static let <name> = """` literal out of the Swift file (closing-delimiter
indentation stripped, `\\`, `\"`, `\n` and line continuations handled; `\(` interpolation is rejected),
concatenates the literals in the order WorldRenderer builds its library, drops the `<metal_*>` includes,
rewrites `1.5h` half literals to `half(1.5)`, and runs `clang++ -fsyntax-only -x c++ -std=c++17` against the shim.

## What it catches

Syntax errors, undeclared names, wrong argument counts, bad swizzle names, vector width mismatches
(`float3 = float4`, `float4(float3)`, `max(float2, float3)`), half/float mixing, wrong struct members,
use before declaration, and matrix/vector product shape errors. Negative tests against the shim caught all of these.

## What it does not catch (a shim is not a Metal compiler)

- Anything specific to Metal's compiler: address-space rules (`device`/`constant`/`thread`/`threadgroup`
  are erased), `[[...]]` attribute validity (unknown attributes are ignored), stage-in/out struct rules,
  buffer/texture index clashes, argument-buffer layout, function-constant use.
- Alignment and layout: `packed_*` and `float3` have C++ layouts here. Matching Swift structs to MSL
  structs still needs a real build or a layout test.
- Metal's overload rules are approximated. The shim is more permissive in places (mixed scalar types,
  `float * int`) and may be stricter or looser than Metal elsewhere. It treats every builtin as returning a default value, so there is no semantic check.
- Texture and sampler methods accept any arguments; only the return type is modelled.
- Atomics, simd and threadgroup helpers exist as stubs; the barrier and memory-scope rules are not checked.
- Swift-side code (`.swift` outside the literals) is not checked at all.

A pass means "parses and type-checks as C++ with these stand-ins". The first real `xcrun metal` compile can
still fail. Run that on a Mac before merging.
