#!/usr/bin/env python3
'''SKYFORGE: syntax-check Metal shading language embedded in Swift string literals.

Extracts `public static let <name> = """ ... """` literals from Swift files, concatenates them the way
WorldRenderer builds its library (CloudShaders.common + WorldShaders.source, then any extra files given),
and runs `clang++ -fsyntax-only -x c++` against tools/msl_check/msl_shim.h.

This is NOT a Metal compiler. See tools/msl_check/README.md for what it can and cannot catch.

Usage:
  tools/msl_check/check_msl.py                       # baseline: Cloud common + World source
  tools/msl_check/check_msl.py Foo.swift Bar.swift   # baseline + extra files' `source` literals
  tools/msl_check/check_msl.py --only X.swift        # just these files (no baseline), as given
  tools/msl_check/check_msl.py Foo.swift:snippet     # pick a literal other than `source`
  tools/msl_check/check_msl.py --dump out.cpp ...    # keep the concatenated translation unit
A bare file name that is not an existing path is looked up in SFRender/Shaders.
'''
import argparse, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SHADERS = os.path.join(ROOT, "Packages/SkyforgeKit/Sources/SFRender/Shaders")
SHIM = os.path.join(HERE, "msl_shim.h")


_SPLICING = []                                          # (enum, name) pairs being expanded: the cycle guard
MAX_SPLICE_DEPTH = 8


def interpolated(enum, name, where):
    key = (enum, name)
    if key in _SPLICING:
        raise SystemExit(f"{where}: interpolation cycle {' -> '.join(f'{e}.{n}' for e, n in _SPLICING + [key])}")
    if len(_SPLICING) >= MAX_SPLICE_DEPTH:
        raise SystemExit(f"{where}: interpolation nested deeper than {MAX_SPLICE_DEPTH} levels")
    for f in sorted(os.listdir(SHADERS)):
        path = os.path.join(SHADERS, f)
        if f.endswith(".swift") and re.search(r"enum\s+" + re.escape(enum) + r"\b", open(path, encoding="utf-8").read()):
            _SPLICING.append(key)
            try: return extract(path, name)[0]
            finally: _SPLICING.pop()
    raise SystemExit(f"{where}: cannot resolve interpolation {enum}.{name}")


def swift_unescape(body, where):
    """Swift multi-line string escapes. Interpolation is rejected: MSL sources must be literal."""
    out, i = [], 0
    simple = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}
    while i < len(body):
        c = body[i]
        if c != "\\":
            out.append(c); i += 1; continue
        n = body[i + 1] if i + 1 < len(body) else ""
        if n in simple: out.append(simple[n]); i += 2
        elif n == "\n": i += 2                        # line continuation
        elif n == "(":
            # `\(OtherEnum.name)`: splice another *Shaders.swift literal (WorldShaders includes AirportSurfaceShaders).
            m = re.match(r"\\\((\w+)\.(\w+)\)", body[i:])
            if not m: raise SystemExit(f"{where}: Swift interpolation \\( in MSL literal is not supported")
            out.append(interpolated(m.group(1), m.group(2), where)); i += m.end()
        elif n == "u":
            m = re.match(r"\\u\{([0-9a-fA-F]+)\}", body[i:])
            if not m: raise SystemExit(f"{where}: bad \\u escape")
            out.append(chr(int(m.group(1), 16))); i += m.end()
        else: raise SystemExit(f"{where}: unknown escape \\{n}")
    return "".join(out)


def strip_indent(raw, where):
    """Swift removes the closing delimiter's indentation from every line."""
    lines = raw.split("\n")
    closing = lines[-1]                                # whitespace before the closing quotes
    if closing.strip(): raise SystemExit(f"{where}: closing \"\"\" must be on its own line")
    body = lines[:-1]
    for k, l in enumerate(body):
        if l.strip() == "": body[k] = ""; continue
        if not l.startswith(closing): raise SystemExit(f"{where}: line indented less than the closing delimiter: {l!r}")
        body[k] = l[len(closing):]
    return "\n".join(body) + ("\n" if body else "")


def extract(path, name="source"):
    text = open(path, encoding="utf-8").read()
    # `let name = """` or `let name = other + """`; the preceding Swift expression is ignored, so a literal
    # that builds on another one (CloudShaders.source = common + ...) yields only its own text.
    pat = re.compile(r"static\s+let\s+" + re.escape(name) + r"\s*(?::\s*String)?\s*=\s*(?:[A-Za-z_][\w.]*\s*\+\s*)?\"\"\"[ \t]*\n")
    m = pat.search(text)
    if not m: raise SystemExit(f"{path}: no `static let {name} = \"\"\"` literal")
    start = m.end()
    j = start
    while True:                                        # closing """ not preceded by a backslash
        k = text.find('"""', j)
        if k < 0: raise SystemExit(f"{path}: unterminated literal")
        bs = 0
        while k - bs - 1 >= 0 and text[k - bs - 1] == "\\": bs += 1
        if bs % 2 == 0: break
        j = k + 3
    line_start = text.rfind("\n", 0, k) + 1
    raw = text[start:line_start] + text[line_start:k]
    where = f"{path}:{name}"
    return swift_unescape(strip_indent(raw, where), where), text.count("\n", 0, start) + 1


def resolve(arg):
    name = "source"
    if ":" in arg and not os.path.exists(arg): arg, name = arg.rsplit(":", 1)
    for cand in (arg, os.path.join(SHADERS, arg), os.path.join(ROOT, arg)):
        if os.path.isfile(cand): return os.path.abspath(cand), name
    raise SystemExit(f"cannot find {arg}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--only", action="store_true", help="do not prepend the baseline (CloudShaders.common + WorldShaders.source)")
    ap.add_argument("--before", action="append", default=[], metavar="FILE",
                    help="a library part placed between CloudShaders.common and WorldShaders.source (MacroColourShaders.swift: world_fragment calls it)")
    ap.add_argument("--dump", metavar="PATH", help="write the concatenated translation unit here and keep it")
    ap.add_argument("--warnings", action="store_true", help="show clang warnings too (noisy: the shim is lax)")
    ap.add_argument("--clang", default=os.environ.get("CLANGXX", "clang++"))
    a = ap.parse_args()

    units = [] if a.only else [(os.path.join(SHADERS, "CloudShaders.swift"), "common")]
    # world_fragment calls MacroColourShaders, which WorldRenderer places before WorldShaders: make that the default.
    if not a.only and not any(os.path.basename(f) == "MacroColourShaders.swift" for f in a.before):
        a.before = ["MacroColourShaders.swift"] + a.before
    units += [resolve(f) for f in a.before]
    units += [] if a.only else [(os.path.join(SHADERS, "WorldShaders.swift"), "source")]
    units += [resolve(f) for f in a.files]
    seen, parts = set(), ['#include "%s"\n' % SHIM]
    for path, name in units:
        if (path, name) in seen: continue
        seen.add((path, name))
        src, first = extract(path, name)  # first: Swift line number of the literal's first line
        src = re.sub(r"^[ \t]*#include\s*<metal_[a-z_]+>[ \t]*$", "", src, flags=re.M)   # the shim replaces the Metal headers
        # Metal's half literal suffix (1.5h) is not C++: rewrite to half(1.5), which keeps the type.
        src = re.sub(r"(?<![\w.])((?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?)h\b", r"half(\1)", src)
        parts.append(f'#line {first} "{os.path.relpath(path, ROOT)}"\n' + src)
    tu = "\n".join(parts)

    fd, tmp = tempfile.mkstemp(suffix=".cpp", prefix="msl_check_")
    os.close(fd)
    open(tmp, "w", encoding="utf-8").write(tu)
    cmd = [a.clang, "-fsyntax-only", "-x", "c++", "-std=c++17", "-ferror-limit=50", "-fno-color-diagnostics"]
    cmd += ["-Wall", "-Wno-unknown-attributes", "-Wno-gnu-anonymous-struct", "-Wno-nested-anon-types"] if a.warnings else ["-w"]
    cmd += [tmp]
    r = subprocess.run(cmd, stderr=subprocess.PIPE, text=True)
    sys.stderr.write(r.stderr)
    if a.dump:
        os.replace(tmp, a.dump); print(f"translation unit kept at {a.dump}")
    else:
        os.unlink(tmp)
    names = ", ".join(f"{os.path.basename(p)}:{n}" for p, n in units)
    if r.returncode == 0: print(f"msl_check OK (shim syntax check only): {names}")
    else: print(f"msl_check FAILED: {names}"); sys.exit(1)


if __name__ == "__main__":
    main()
