#!/usr/bin/env python3
"""SKYFORGE build-time tool: OpenStreetMap building footprints for a showcase region.

Source: the Overture Maps Foundation "buildings" theme on AWS Open Data (public bucket, no key,
no account): s3://overturemaps-us-west-2/release/<release>/theme=buildings/type=building/.
Only records whose primary source is OpenStreetMap are kept, so the output is plain OSM data
(© OpenStreetMap contributors, ODbL 1.0) and no machine-learned third-party footprints ship.

The tool reads each Parquet footer by HTTP range, keeps a local index of row-group bounding boxes
(so later regions need no footer downloads), and fetches only the row groups that intersect the box.

Output: a compact binary (`SFB1`) read by `SFQuickFlight.BuildingPack`:
  magic "SFB1" | f64 lat0 | f64 lon0 | u32 count | records...
  record: i32 x_dm, i32 y_dm (first vertex, decimetres east/north of lat0/lon0) | u16 height_dm |
          u16 min_height_dm | u8 kind | u8 roof | u8 levels | u8 flags | u8 r,g,b (roof, 0 = none) |
          u8 r,g,b (wall, 0 = none) | u16 n | n-1 × (i16 dx_dm, i16 dy_dm) relative to the previous vertex

Source filter: --sources (default "OpenStreetMap"). docs/DECISIONS.md forbids shipping Microsoft ML / Google Open
Buildings / Esri footprints, so the default drops them; pass e.g. --sources OpenStreetMap,"Microsoft ML Buildings"
only after that decision is revisited (licences and attribution differ per source; see docs/rounds/ROUND2.md).

Height and roof inference (on by default, --no-infer restores the raw attributes): a record with no height gets
one from its storeys, else from class, footprint area and aspect ratio, with a deterministic ±jitter keyed on its
position; a record with no roof:shape gets gabled or hipped (small houses, sheds, churches) or flat (everything
else). Flags byte: bit0 height present in the source (left clear for inferred heights so Swift keeps its own estimate), bit1 has parts, bit2 height inferred, bit3 roof inferred. SFB1 layout is
unchanged, so BuildingPack reads it as before.

Usage: fetch_buildings.py --lat 47.53 --lon -122.30 --half-km 6 --out KBFI/buildings.sfb [--release 2026-10-21.0]
"""
import argparse, math, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from overture_common import (BUCKET, RangeFile, box_or_exit, fnum, footer_index, parse_sources, polygons, project_ring,
                             row_bbox_hit, row_groups_in_box, source_allowed, source_dataset, write_output)

KINDS = ["yes", "house", "residential", "apartments", "commercial", "industrial", "retail", "office", "warehouse",
         "hangar", "garage", "shed", "church", "school", "hospital", "hotel", "civic", "transportation", "roof",
         "agricultural", "service", "religious", "education", "medical", "entertainment", "military", "outbuilding"]
ROOFS = ["", "flat", "gabled", "hipped", "pyramidal", "skillion", "gambrel", "mansard", "dome", "round", "onion", "saltbox",
         "half_hipped", "sawtooth", "cone", "spherical"]
FLAT_ROOF_KINDS = {"apartments", "commercial", "industrial", "retail", "office", "warehouse", "hangar", "hotel", "civic",
                   "school", "hospital", "education", "medical", "transportation", "entertainment", "military", "agricultural"}
PITCHED_KINDS = {"house", "residential", "garage", "shed", "outbuilding", "church", "religious", "yes", "service", "roof"}


def colour(s):
    if not s: return (0, 0, 0)
    s = s.strip().lower()
    if s.startswith("#") and len(s) == 7:
        try: return tuple(max(1, int(s[i:i + 2], 16)) for i in (1, 3, 5))
        except ValueError: return (0, 0, 0)
    return (0, 0, 0)


def ring_area(pts):
    return abs(sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))) / 2


def convex_hull(pts):
    pts = sorted(set(pts))
    if len(pts) < 3: return pts
    def half(seq):
        h = []
        for p in seq:
            while len(h) >= 2 and (h[-1][0] - h[-2][0]) * (p[1] - h[-2][1]) - (h[-1][1] - h[-2][1]) * (p[0] - h[-2][0]) <= 0: h.pop()
            h.append(p)
        return h
    lo, up = half(pts), half(reversed(pts))
    return lo[:-1] + up[:-1]


def aspect_ratio(pts):
    """Long side / short side of the minimum-area oriented bounding box (metres in, >= 1 out)."""
    hull = convex_hull(pts)
    if len(hull) < 3: return 1.0
    best = None
    for i in range(len(hull)):
        a, b = hull[i], hull[(i + 1) % len(hull)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        l = math.hypot(dx, dy)
        if l < 1e-6: continue
        ux, uy = dx / l, dy / l
        us = [p[0] * ux + p[1] * uy for p in hull]; vs = [-p[0] * uy + p[1] * ux for p in hull]
        w, h = max(us) - min(us), max(vs) - min(vs)
        if best is None or w * h < best[0]: best = (w * h, max(w, h), max(1e-3, min(w, h)))
    return 1.0 if best is None else best[1] / best[2]


def jitter(x_dm, y_dm):
    """Deterministic 0..1 from the first vertex, so reruns and neighbouring releases give the same heights."""
    h = (x_dm * 0x9E3779B1 + y_dm * 0x85EBCA6B) & 0xFFFFFFFF
    h ^= h >> 15; h = (h * 0x2C1B3C6D) & 0xFFFFFFFF; h ^= h >> 12
    return (h & 0xFFFF) / 65535.0


def infer_height(kind, area, floors, u):
    """Metres. Calibrated on typical US suburban stock: houses 5-8 m, strip retail 5-7 m, apartments 3-5 storeys."""
    if floors: return floors * 3.2 + 1.0
    if kind in ("garage", "shed", "outbuilding", "roof") or area < 28: return 3.0 + 0.4 * u
    if kind in ("house", "residential") or (kind in ("yes", "service") and area < 420):
        return 5.0 + 3.0 * u if area < 220 else 6.0 + 2.5 * u
    if kind in ("apartments", "hotel"):
        step = min(2, int(u * 3))                   # u == 1.0 must not push past the top storey count
        return 3.2 * (3 + step) + 1.0 if area < 1800 else 3.2 * (2 + step) + 1.0
    if kind in ("church", "religious"): return 10 + 4 * u
    if kind in ("school", "hospital", "education", "medical", "civic"): return 7.5 + 4 * u
    if kind in ("industrial", "warehouse", "hangar"): return 7 + 5 * u if area < 4000 else 9 + 4 * u
    if kind in ("commercial", "retail", "office"): return 5 + 2 * u if area > 2500 else 6 + 8 * u * (1 if area < 800 else 0.5)
    if area < 120: return 4.0 + 2.0 * u
    if area < 420: return 5.5 + 2.5 * u
    return 7.0 + 4.0 * u if area < 2500 else 8.0 + 3.0 * u


def infer_roof(kind, area, aspect, floors, height):
    """Index into ROOFS: gabled (elongated) or hipped (squat) on small pitched stock, flat on everything large."""
    if area > 650 or (kind in FLAT_ROOF_KINDS and area > 90): return ROOFS.index("flat")
    if kind in PITCHED_KINDS or kind in ("yes",) or area < 650:
        if area < 20: return ROOFS.index("flat")
        return ROOFS.index("gabled" if aspect >= 1.35 else "hipped")
    return ROOFS.index("flat")


def encode(rows, lat, lon, mlat, mlon, infer, stats):
    """SFB1 bytes and the record count. Rows that cannot be encoded are counted in stats ("bad_geometry",
    "bad_ring", "too_long") instead of aborting the run."""
    out = bytearray(b"SFB1") + struct.pack("<ddI", lat, lon, 0)
    count = 0
    for r in rows:
        geom = r.get("geometry")
        if not geom: stats["bad_geometry"] += 1; continue
        try: rings = polygons(geom)
        except ValueError: stats["bad_geometry"] += 1; continue
        kind = str(r.get("class") or r.get("subtype") or "yes").lower()
        ki = KINDS.index(kind) if kind in KINDS else 0
        kname = KINDS[ki]
        ro = str(r.get("roof_shape") or "").lower()
        ri = ROOFS.index(ro) if ro in ROOFS else 0
        h = fnum(r.get("height")); floors = fnum(r.get("num_floors")); mh = fnum(r.get("min_height")) or 0
        flags = (1 if h else 0) | (2 if r.get("has_parts") else 0)
        rc, wc = colour(r.get("roof_color")), colour(r.get("facade_color"))
        for ring in rings:
            pts = project_ring(ring, lat, lon, mlat, mlon)
            if pts is None: stats["bad_ring"] += 1; continue
            if len(pts) > 1 and pts[0] == pts[-1]: pts = pts[:-1]
            ded = [pts[0]] if pts else []
            for p in pts[1:]:
                if p != ded[-1]: ded.append(p)
            if len(ded) < 3: continue
            if len(ded) > 4000 or any(abs(ded[i][0] - ded[i - 1][0]) > 32767 or abs(ded[i][1] - ded[i - 1][1]) > 32767 for i in range(1, len(ded))):
                stats["too_long"] += 1; continue
            hh, f2, rr = h, flags, ri
            if infer:
                m = [(x / 10.0, y / 10.0) for x, y in ded]
                area = ring_area(m)
                asp = aspect_ratio(m) if (not ri or not hh) else 1.0
                if not hh:
                    hh = infer_height(kname, area, floors, jitter(*ded[0])); f2 |= 4
                    stats["height_inferred"] += 1
                if not ri:
                    rr = infer_roof(kname, area, asp, floors, hh); f2 |= 8
                    stats["roof_inferred"] += 1
                stats["roof_" + ROOFS[rr]] += 1
            hd = int(max(0, min(65535, round((hh or 0) * 10))))
            out += struct.pack("<iiHHBBBB3B3BH", ded[0][0], ded[0][1], hd, int(max(0, min(65535, round(mh * 10)))), ki, rr,
                               int(max(0, min(255, floors or 0))), f2, *rc, *wc, len(ded))
            for i in range(1, len(ded)):
                out += struct.pack("<hh", ded[i][0] - ded[i - 1][0], ded[i][1] - ded[i - 1][1])
            count += 1
    struct.pack_into("<I", out, 20, count)
    return out, count


def main():
    import pyarrow.parquet as pq
    from collections import Counter
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True); ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half-km", type=float, default=6.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--release", default="2026-10-21.0")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/skyforge-overture"))
    ap.add_argument("--sources", default="OpenStreetMap",
                    help='comma-separated Overture source datasets to keep ("any" keeps all); default OpenStreetMap only')
    ap.add_argument("--no-infer", action="store_true", help="write raw heights and roofs (no inference)")
    ap.add_argument("--allow-empty", action="store_true", help="allow a zero-record result to replace an existing output")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    allow = parse_sources(a.sources)
    if allow != {"OpenStreetMap"}:
        print("WARNING: non-OSM sources selected; docs/DECISIONS.md forbids shipping them. Licences and attribution"
              " differ per dataset (see docs/rounds/ROUND2.md).", file=sys.stderr)
    box0, box1, box2, box3, mlat, mlon = box_or_exit(ap, a.lat, a.lon, a.half_km)
    box = (box0, box1, box2, box3)
    index = footer_index(a.release, a.cache)
    wanted = ["geometry", "bbox", "sources", "subtype", "class", "height", "num_floors", "min_height", "roof_shape",
              "roof_color", "facade_color", "roof_height", "has_parts", "is_underground"]
    rows, kept, skipped, nobbox = [], 0, Counter(), 0
    for key, size, hit in row_groups_in_box(index, box):
        f = RangeFile(f"{BUCKET}/{key}", size, block=4 << 20)
        pf = pq.ParquetFile(f)
        have = set(pf.schema_arrow.names)
        cols = [c for c in wanted if c in have]
        for g in hit:
            for r in pf.read_row_group(g, columns=cols).to_pylist():
                inbox = row_bbox_hit(r, box)
                if not inbox: nobbox += inbox is None; continue
                ds = source_dataset(r)
                if not source_allowed(r, allow): skipped[ds or "unknown"] += 1; continue
                if r.get("is_underground"): continue
                rows.append(r); kept += 1
            print(f"  {os.path.basename(key)[:10]} group {g}: {kept} kept ({f.fetched >> 20} MiB)", file=sys.stderr, flush=True)
    stats = Counter()
    out, count = encode(rows, a.lat, a.lon, mlat, mlon, not a.no_infer, stats)
    write_output(a.out, out, count, a.allow_empty)
    bad = {k: stats[k] for k in ("bad_geometry", "bad_ring", "too_long") if stats[k]}
    print(f"{a.out}: {count} footprints, {len(out) >> 10} KiB; skipped by source: {dict(skipped)}"
          f"{'; rows without a usable bbox: %d' % nobbox if nobbox else ''}{'; unencodable: %s' % bad if bad else ''}", file=sys.stderr)
    if not a.no_infer:
        print(f"inferred: {stats['height_inferred']} heights, {stats['roof_inferred']} roofs; roofs now: "
              f"flat {stats['roof_flat']}, gabled {stats['roof_gabled']}, hipped {stats['roof_hipped']}", file=sys.stderr)


if __name__ == "__main__":
    main()
