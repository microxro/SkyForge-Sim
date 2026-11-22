#!/usr/bin/env python3
"""SKYFORGE build-time tool: OpenStreetMap road centrelines for a showcase region.

Source: the Overture Maps Foundation "transportation" theme (type=segment) on AWS Open Data (public
bucket, no key). By default only records whose primary source is OpenStreetMap are kept (--sources widens
the allow-list; docs/DECISIONS.md forbids non-OSM sources until revisited), so the output is OSM data
(© OpenStreetMap contributors, ODbL 1.0). Row groups are found through a cached bounding-box index, as
in fetch_buildings.py.

Output: a compact binary (`SFR1`) read by `SFQuickFlight.RoadPack`:
  magic "SFR1" | f64 lat0 | f64 lon0 | u32 count | records...
  record: u8 class | u8 flags (1 link, 2 bridge, 4 tunnel, 8 unpaved) | u16 n |
          i32 x_dm, i32 y_dm (first point, decimetres east/north of lat0/lon0) |
          n-1 × (i16 dx_dm, i16 dy_dm) relative to the previous point

Usage: fetch_roads.py --lat 47.53 --lon -122.30 --half-km 6 --out KBFI/roads.sfr [--release 2026-10-21.0]
"""
import argparse, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from overture_common import (BUCKET, RangeFile, box_or_exit, dedup_split, footer_index, lines, parse_sources, project_ring,
                             row_bbox_hit, row_groups_in_box, source_allowed, write_output)

CLASSES = ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "living_street",
           "service", "track"]
UNPAVED = {"unpaved", "dirt", "gravel", "ground", "earth", "sand", "grass", "compacted", "fine_gravel", "mud"}


def linestring(wkb):
    """The vertices of a single LineString (ValueError for anything else or for malformed bytes)."""
    found = lines(wkb)
    if len(found) != 1: raise ValueError("expected one LineString")
    return found[0]


def flagged(rules, name):
    """True when a `road_flags`-style rule list sets `name` over the whole segment or most of it."""
    for r in rules or []:
        if name in (r.get("values") or []):
            b = r.get("between")
            if not b or (b[1] - b[0]) > 0.5:
                return True
    return False


def main():
    import pyarrow.parquet as pq
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half-km", type=float, default=6.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--release", default="2026-10-21.0")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/skyforge-overture"))
    ap.add_argument("--sources", default="OpenStreetMap",
                    help='comma-separated Overture source datasets to keep ("any" keeps all); default OpenStreetMap only')
    ap.add_argument("--allow-empty", action="store_true", help="allow a zero-road result to replace an existing output")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    allow = parse_sources(a.sources)
    if allow != {"OpenStreetMap"}:
        print("WARNING: non-OSM sources selected; docs/DECISIONS.md forbids shipping them.", file=sys.stderr)
    b0, b1, b2, b3, mlat, mlon = box_or_exit(ap, a.lat, a.lon, a.half_km)
    box = (b0, b1, b2, b3)
    index = footer_index(a.release, a.cache, "transportation", "segment")
    wanted = ["geometry", "bbox", "sources", "subtype", "class", "subclass", "road_surface", "road_flags"]
    out = bytearray(b"SFR1") + struct.pack("<ddI", a.lat, a.lon, 0)
    count = skipped = nobbox = badgeom = 0
    for key, size, hit in row_groups_in_box(index, box):
        f = RangeFile(f"{BUCKET}/{key}", size, block=4 << 20)
        pf = pq.ParquetFile(f)
        cols = [c for c in wanted if c in set(pf.schema_arrow.names)]
        for g in hit:
            for r in pf.read_row_group(g, columns=cols).to_pylist():
                hit_box = row_bbox_hit(r, box)
                if not hit_box:
                    nobbox += hit_box is None
                    continue
                if (r.get("subtype") or "") != "road":
                    continue
                cls = (r.get("class") or "").lower()
                if cls not in CLASSES:
                    continue
                sub = (r.get("subclass") or "").lower()
                if sub in ("driveway", "sidewalk", "crosswalk", "cycle_crossing"):
                    continue
                if not source_allowed(r, allow):
                    skipped += 1
                    continue
                try:
                    line = linestring(r.get("geometry"))
                except ValueError:
                    badgeom += 1
                    continue
                flags = (1 if sub == "link" else 0) | (2 if flagged(r.get("road_flags"), "is_bridge") else 0) \
                    | (4 if flagged(r.get("road_flags"), "is_tunnel") else 0)
                surf = r.get("road_surface") or []
                if any((s.get("value") or "") in UNPAVED and not s.get("between") for s in surf):
                    flags |= 8
                pts = project_ring(line, a.lat, a.lon, mlat, mlon)
                if not pts:
                    badgeom += 1
                    continue
                ded = dedup_split(pts)          # steps longer than an i16 of decimetres are split
                if len(ded) < 2 or len(ded) > 60_000:
                    continue
                out += struct.pack("<BBHii", CLASSES.index(cls), flags, len(ded), ded[0][0], ded[0][1])
                for p, q in zip(ded[1:], ded[:-1]):
                    out += struct.pack("<hh", p[0] - q[0], p[1] - q[1])
                count += 1
            print(f"  {os.path.basename(key)[:10]} group {g}: {count} kept ({f.fetched >> 20} MiB)", file=sys.stderr, flush=True)
    struct.pack_into("<I", out, 20, count)
    write_output(a.out, out, count, a.allow_empty)
    print(f"{a.out}: {count} roads, {len(out)} bytes ({skipped} records dropped by --sources, {badgeom} unusable geometries, {nobbox} without a bbox)")


if __name__ == "__main__":
    main()
