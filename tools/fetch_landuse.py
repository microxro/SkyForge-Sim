#!/usr/bin/env python3
"""SKYFORGE build-time tool: Overture Maps base-theme land-use polygons for a showcase region.

Source: s3://overturemaps-us-west-2/release/<release>/theme=base/type=land_use/ (public, no key). Records are
filtered by their primary source dataset (--sources, default OpenStreetMap only; see docs/DECISIONS.md), mapped to a
small category enum, and written as polygons for the suburban parcel generator (SFRender SuburbShaders) and the
airport ground mask.

Output: compact binary `SFL1`, read by `SFQuickFlight.LandUsePack`:
  magic "SFL1" | f64 lat0 | f64 lon0 | u32 count | records...
  record: u8 category | u8 flags (bit0 = surface says paved) | u16 n | i32 x_dm, i32 y_dm (first vertex, decimetres
          east/north of lat0/lon0) | n-1 x (i16 dx_dm, i16 dy_dm) relative to the previous vertex
Only outer rings are stored (holes are dropped; parcel generation treats a polygon as solid, overlapping smaller
categories win by draw order, so records are written largest area first).

Usage: fetch_landuse.py --lat 47.53 --lon -122.30 --half-km 6 --out KBFI/landuse.sfl [--list-classes]
"""
import argparse, math, os, struct, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from overture_common import BUCKET, RangeFile, dedup_split, footer_index, parse_sources, polygons, region_box, row_groups_in_box, source_allowed, source_dataset

CATEGORIES = ["other", "residential", "commercial", "industrial", "park", "agricultural", "airport", "institutional",
              "cemetery", "golf", "natural", "transport"]
# Overture land_use `class` (and subtype fallback) -> category index.
CLASS_MAP = {
    "residential": 1, "garden": 4, "allotments": 5, "village_green": 4,
    "commercial": 2, "retail": 2, "retail_area": 2, "hotel": 2,
    "industrial": 3, "construction": 3, "quarry": 3, "landfill": 3, "military": 3, "railway": 11,
    "park": 4, "recreation_ground": 4, "playground": 4, "pitch": 4, "grass": 4, "dog_park": 4, "picnic_site": 4,
    "stadium": 4, "track": 4, "swimming_pool": 4, "protected": 10, "nature_reserve": 10, "natural": 10,
    "farmland": 5, "farmyard": 5, "orchard": 5, "vineyard": 5, "agriculture": 5, "plant_nursery": 5, "greenhouse_horticulture": 5,
    "aerodrome": 6, "airport": 6, "runway": 6, "taxiway": 6, "apron": 6, "helipad": 6, "heliport": 6,
    "school": 7, "university": 7, "college": 7, "hospital": 7, "clinic": 7, "kindergarten": 7, "religious": 7, "cemetery": 8,
    "golf_course": 9, "tee": 9, "fairway": 9, "bunker": 9, "green": 9, "meadow": 5, "schoolyard": 7, "brownfield": 3, "marina": 11, "parking": 11, "pedestrian": 11, "bus_station": 11, "railway_station": 11,
}
SUBTYPE_MAP = {"residential": 1, "agriculture": 5, "park": 4, "recreation": 4, "protected": 10, "education": 7,
               "medical": 7, "cemetery": 8, "golf": 9, "airport": 6, "transportation": 11, "industrial": 3,
               "commercial": 2, "military": 3, "entertainment": 4, "religious": 7, "horticulture": 5}


def category(rec):
    c = (rec.get("class") or "").lower()
    if c in CLASS_MAP: return CLASS_MAP[c]
    return SUBTYPE_MAP.get((rec.get("subtype") or "").lower(), 0)


def ring_area(pts):
    return abs(sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))) / 2


def encode(rows, lat, lon, mlat, mlon):
    polys = []
    for r in rows:
        try: rings = polygons(r["geometry"])
        except Exception: continue
        cat = category(r)
        flags = 1 if (r.get("surface") or "") in ("paved", "asphalt", "concrete") else 0
        for ring in rings:
            pts = [(round((lo - lon) * mlon * 10), round((la - lat) * mlat * 10)) for lo, la in ring]
            if len(pts) > 1 and pts[0] == pts[-1]: pts = pts[:-1]
            ded = dedup_split(pts)                 # long edges are subdivided, not dropped (i16 decimetre deltas)
            if ded and ded[0] == ded[-1]: ded.pop()
            if len(ded) < 3 or len(ded) > 20000: continue
            polys.append((ring_area(ded), cat, flags, ded))
    polys.sort(key=lambda p: -p[0])           # largest first, small categories draw on top
    out = bytearray(b"SFL1") + struct.pack("<ddI", lat, lon, len(polys))
    for _, cat, flags, ded in polys:
        out += struct.pack("<BBHii", cat, flags, len(ded), ded[0][0], ded[0][1])
        for i in range(1, len(ded)):
            out += struct.pack("<hh", ded[i][0] - ded[i - 1][0], ded[i][1] - ded[i - 1][1])
    return out, polys


def main():
    import pyarrow.parquet as pq
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True); ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half-km", type=float, default=6.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--release", default="2026-10-21.0")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/skyforge-overture"))
    ap.add_argument("--sources", default="OpenStreetMap")
    ap.add_argument("--list-classes", action="store_true", help="print class/subtype/source counts and exit without writing")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    allow = parse_sources(a.sources)
    if allow != {"OpenStreetMap"}:
        print("WARNING: non-OSM sources selected; docs/DECISIONS.md forbids shipping them.", file=sys.stderr)
    b0, b1, b2, b3, mlat, mlon = region_box(a.lat, a.lon, a.half_km)
    box = (b0, b1, b2, b3)
    index = footer_index(a.release, a.cache, "base", "land_use")
    rows, skipped, classes = [], Counter(), Counter()
    for key, size, hit in row_groups_in_box(index, box):
        pf = pq.ParquetFile(RangeFile(f"{BUCKET}/{key}", size, block=4 << 20))
        have = set(pf.schema_arrow.names)
        cols = [c for c in ("geometry", "bbox", "sources", "subtype", "class", "surface") if c in have]
        for g in hit:
            for r in pf.read_row_group(g, columns=cols).to_pylist():
                bb = r["bbox"]
                if bb["xmax"] < box[0] or bb["xmin"] > box[1] or bb["ymax"] < box[2] or bb["ymin"] > box[3]: continue
                ds = source_dataset(r)
                classes[(r.get("subtype"), r.get("class"), ds)] += 1
                if not source_allowed(r, allow): skipped[ds or "unknown"] += 1; continue
                rows.append(r)
    if a.list_classes:
        for k, v in sorted(classes.items(), key=lambda kv: -kv[1]): print(v, k)
        return
    out, polys = encode(rows, a.lat, a.lon, mlat, mlon)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "wb").write(out)
    per = Counter(CATEGORIES[p[1]] for p in polys)
    print(f"{a.out}: {len(polys)} polygons, {len(out) >> 10} KiB; {dict(per)}; skipped by source: {dict(skipped)}", file=sys.stderr)


if __name__ == "__main__":
    main()
