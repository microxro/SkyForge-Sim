#!/usr/bin/env python3
"""SKYFORGE build-time tool: airport surface polygons for the procedural airport material.

Source: Overture Maps Foundation, release 2026-10-21.0 (anonymous S3 read), records whose primary source
is OpenStreetMap only (ODbL 1.0; no machine-learned third-party data, see docs/DECISIONS.md and
docs/DATA_SOURCES.md). Pass --all-sources to disable the filter (then attribution of every dataset applies).
  * theme=base/type=infrastructure, subtype=airport: class runway, taxiway, apron (polygons or lines),
    helipad and others are kept as "other pavement"
  The aerodrome boundary is the `regional_airport` (and similar) polygon of the same infrastructure rows;
  base/type=land_use carries no airport rows in release 2026-10-21.0.

Output `SFA1` (little endian):
  "SFA1" | f64 lat0 | f64 lon0 | u32 count | records
  record: u8 surface (0 boundary, 1 apron, 2 taxiway/other pavement, 3 runway) |
          u8 geometry (bit 0: 0 polygon, 1 line; bit 1: unpaved (grass, dirt, gravel...), drawn as infield, not pavement;
          readers that compare the byte to 0/1 only see old files) |
          u16 width_dm (lines; 0 = default for the surface) | u16 n | i32 x_dm, i32 y_dm (first vertex, decimetres
          east/north of lat0/lon0) | (n-1) × (i16 dx_dm, i16 dy_dm)
Rasterised by the renderer (`AirportSurfaces.rasterise`; `--png` writes a preview) into the rg8Unorm `airportMask` texture (R coverage, G class):
  0 = not airport, 0.33 = apron, 0.66 = taxiway / other pavement, 1.0 = runway (boundary only = 0.10 "airfield").

Usage: fetch_airport_surfaces.py --lat 36.5870 --lon -121.8430 --half-km 3 --out KMRY/airport.sfa [--png mask.png --png-size 2048]
"""
import argparse, math, os, re, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from overture_common import (BUCKET, RangeFile, box_or_exit, dedup_split, footer_index, geom_kind, lines, parse_sources,
                             polygons, project_ring, row_bbox_hit, row_groups_in_box, source_allowed, write_output)

RELEASE = "2026-10-21.0"
SURFACE = {"boundary": 0, "apron": 1, "taxiway": 2, "runway": 3}
DEFAULT_WIDTH_M = {"runway": 30.0, "taxiway": 15.0, "apron": 20.0}
MASK_VALUE = {0: 0.10, 1: 0.33, 2: 0.66, 3: 1.0}


_WIDTH = re.compile(r"^\s*(\d+(?:[.,]\d+)?)\s*(m|meters?|metres?|ft|feet|')?\s*$", re.I)


def width_of(r):
    """Paved width (m) from the OSM `width` tag carried in source_tags (list of (key, value) or a dict); 0 = unknown, and the
    renderer then uses the primary runway's own width or its per-surface default (runway 30 m, taxiway 15 m). Understands
    "30", "30 m", "98 ft" and "98'"; an empty, non-numeric or out-of-range value is unknown."""
    tags = r.get("source_tags") or {}
    items = tags.items() if isinstance(tags, dict) else tags
    for k, v in items:
        if k in ("width", "aeroway:width"):
            m = _WIDTH.match(str(v))
            if not m: return 0.0
            w = float(m.group(1).replace(",", "."))
            if (m.group(2) or "").lower() in ("ft", "feet", "'"): w *= 0.3048
            return max(0.0, min(150.0, w))
    return 0.0


UNPAVED = {"grass", "dirt", "gravel", "fine_gravel", "ground", "unpaved", "sand", "earth", "compacted", "mud", "clay",
           "grass_paver", "soil", "turf"}


def is_unpaved(r):
    """True when the OSM surface (Overture `surface` column or the source tag) is a natural / unpaved one."""
    vals = [str(r.get("surface") or "")]
    tags = r.get("source_tags") or {}
    items = tags.items() if isinstance(tags, dict) else tags
    vals += [str(v) for k, v in items if k == "surface"]
    return any(v.strip().lower() in UNPAVED for v in vals)


def scan(box, cache, want, allow):
    """Infrastructure rows in `box` accepted by `want` and the source allow-list: (rows, dropped by source, rows with
    no usable bbox)."""
    import pyarrow.parquet as pq
    rows, dropped, nobbox = [], 0, 0
    for key, size, hit in row_groups_in_box(footer_index(RELEASE, cache, "base", "infrastructure"), box):
        f = RangeFile(f"{BUCKET}/{key}", size, block=4 << 20)
        pf = pq.ParquetFile(f)
        cols = [c for c in ("geometry", "bbox", "sources", "subtype", "class", "surface", "source_tags") if c in pf.schema_arrow.names]
        for g in hit:
            for r in pf.read_row_group(g, columns=cols).to_pylist():
                inbox = row_bbox_hit(r, box)
                if not inbox: nobbox += inbox is None; continue
                if not want(r): continue
                if not source_allowed(r, allow): dropped += 1; continue
                rows.append(r)
    return rows, dropped, nobbox


def surface_of(cls):
    cls = (cls or "").lower()
    if cls == "runway": return "runway"
    if cls.endswith("airport") or cls in ("aerodrome", "airfield", "airstrip"): return "boundary"   # e.g. regional_airport polygon
    if cls == "apron": return "apron"
    return "taxiway"     # taxiway, taxilane, helipad, parking positions, holding positions, ...


def parts(r):
    """[(surface name, kind, unpaved, points)] for one record, or None if its geometry is unusable."""
    geom = r.get("geometry")
    s, k, unpaved = surface_of(r.get("class")), geom_kind(geom), is_unpaved(r)
    try:
        if k == "polygon": return [(s, "polygon", unpaved, ring) for ring in polygons(geom)]
        if k == "line": return [(s, "line", unpaved, ln) for ln in lines(geom)]
    except ValueError:
        return None
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True); ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half-km", type=float, default=3.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--all-sources", action="store_true", help="keep non-OSM Overture sources (NOT the project default; see DECISIONS.md)")
    ap.add_argument("--allow-empty", action="store_true", help="allow a zero-feature result to replace an existing output")
    ap.add_argument("--survey", action="store_true", help="print class histograms of airport-related rows and exit")
    ap.add_argument("--png", help="also write the rasterised r8 mask (north up) to this PNG")
    ap.add_argument("--png-size", type=int, default=2048, help="PNG side in pixels, 64-8192")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/skyforge-overture"))
    a = ap.parse_args()
    if not 64 <= a.png_size <= 8192: ap.error("--png-size must be between 64 and 8192")
    os.makedirs(a.cache, exist_ok=True)
    b0, b1, b2, b3, mlat, mlon = box_or_exit(ap, a.lat, a.lon, a.half_km)
    box = (b0, b1, b2, b3)
    allow = None if a.all_sources else parse_sources("OpenStreetMap")

    infra, d1, nobbox = scan(box, a.cache, lambda r: (r.get("subtype") or "") == "airport", allow)
    if a.survey:
        from collections import Counter
        print("infrastructure/airport classes:", Counter((r.get("class"), geom_kind(r.get("geometry"))) for r in infra))
        return

    out = bytearray(b"SFA1") + struct.pack("<ddI", a.lat, a.lon, 0)
    counts, skipped = {}, {"bad_geometry": 0, "bad_ring": 0, "too_big": 0}

    def emit(surface, kind, width_m, pts, unpaved=False):
        nonlocal out
        q = project_ring(pts, a.lat, a.lon, mlat, mlon)
        if q is None: skipped["bad_ring"] += 1; return
        if kind == "polygon" and len(q) > 1 and q[0] == q[-1]: q = q[:-1]
        ded = dedup_split(q)                       # long edges are subdivided (i16 decimetre deltas), never dropped
        if kind == "polygon" and len(ded) > 1 and ded[0] == ded[-1]: ded.pop()
        if len(ded) < (3 if kind == "polygon" else 2): return
        if len(ded) > 20000: skipped["too_big"] += 1; return
        out += struct.pack("<BBHHii", SURFACE[surface], (0 if kind == "polygon" else 1) | (2 if unpaved else 0), int(round(width_m * 10)), len(ded), *ded[0])
        for i in range(1, len(ded)): out += struct.pack("<hh", ded[i][0] - ded[i - 1][0], ded[i][1] - ded[i - 1][1])
        counts[(surface, kind)] = counts.get((surface, kind), 0) + 1

    usable = []
    for r in infra:
        ps = parts(r)
        if ps is None: skipped["bad_geometry"] += 1; continue
        usable.append((r, ps))
        for s, k, unpaved, pts in ps:
            emit(s, k, width_of(r) if k == "line" else 0, pts, unpaved)
    n = sum(counts.values())
    struct.pack_into("<I", out, 20, n)
    write_output(a.out, out, n, a.allow_empty)
    bad = {k: v for k, v in skipped.items() if v}
    print(f"{a.out}: {n} features {dict(counts)}, {len(out)} B; {d1} non-OSM records skipped"
          f"{'; rows without a usable bbox: %d' % nobbox if nobbox else ''}{'; unencodable: %s' % bad if bad else ''}", file=sys.stderr)

    if a.png:
        from PIL import Image, ImageDraw
        S = a.png_size; px = 2 * a.half_km * 1000 / S
        img = Image.new("L", (S, S), 0); dr = ImageDraw.Draw(img)
        def to_px(lon, lat): return ((lon - a.lon) * mlon / px + S / 2, S / 2 - (lat - a.lat) * mlat / px)
        items = []
        for r, ps in usable:
            for s, k, unpaved, pts in ps:
                if unpaved: continue                   # unpaved strips are infield, not pavement
                w = width_of(r) or DEFAULT_WIDTH_M.get(s, 15.0) if k == "line" else 0
                items.append((SURFACE[s], k, w, pts))
        for s, k, w, pts in sorted(items, key=lambda t: (t[0] == 3, t[0])):   # runway last (on top); boundary first
            v = int(MASK_VALUE[s] * 255); p = [to_px(*q) for q in pts if all(math.isfinite(c) for c in q)]
            if len(p) < 2: continue
            if k == "polygon": dr.polygon(p, fill=v)
            else: dr.line(p, fill=v, width=max(1, round(w / px)))
        img.save(a.png); print(f"{a.png}: {S}² at {px:.2f} m/px", file=sys.stderr)


if __name__ == "__main__":
    main()
