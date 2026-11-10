#!/usr/bin/env python3
"""SKYFORGE build-time tool: OpenStreetMap road centrelines for a showcase region.

Source: the Overture Maps Foundation "transportation" theme (type=segment) on AWS Open Data (public
bucket, no key). Only records whose primary source is OpenStreetMap are kept, so the output is OSM data
(© OpenStreetMap contributors, ODbL 1.0). Row groups are found through a cached bounding-box index, as
in fetch_buildings.py.

Output: a compact binary (`SFR1`) read by `SFQuickFlight.RoadPack`:
  magic "SFR1" | f64 lat0 | f64 lon0 | u32 count | records...
  record: u8 class | u8 flags (1 link, 2 bridge, 4 tunnel, 8 unpaved) | u16 n |
          i32 x_dm, i32 y_dm (first point, decimetres east/north of lat0/lon0) |
          n-1 × (i16 dx_dm, i16 dy_dm) relative to the previous point

Usage: fetch_roads.py --lat 47.53 --lon -122.30 --half-km 6 --out KBFI/roads.sfr [--release 2026-10-21.0]
"""
import argparse, json, math, os, re, struct, sys

import fetch_buildings as fb

CLASSES = ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "living_street",
           "service", "track"]
UNPAVED = {"unpaved", "dirt", "gravel", "ground", "earth", "sand", "grass", "compacted", "fine_gravel", "mud"}


def list_files(release):
    keys, token = [], None
    while True:
        url = f"{fb.BUCKET}/?list-type=2&prefix=release/{release}/theme=transportation/type=segment/&max-keys=1000"
        if token:
            url += "&continuation-token=" + fb.requests.utils.quote(token)
        x = fb.SESSION.get(url, timeout=60).text
        for m in re.finditer(r"<Contents>(.*?)</Contents>", x, re.S):
            k = re.search(r"<Key>([^<]+)</Key>", m.group(1)).group(1)
            s = int(re.search(r"<Size>(\d+)</Size>", m.group(1)).group(1))
            if k.endswith(".parquet"):
                keys.append((k, s))
        t = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", x)
        if not t:
            return keys
        token = t.group(1)


def footer_index(release, cache_dir):
    import pyarrow.parquet as pq
    path = os.path.join(cache_dir, f"overture-segments-{release}.index.json")
    index = json.load(open(path)) if os.path.exists(path) else {}
    files = list_files(release)
    dirty = 0
    for n, (key, size) in enumerate(files):
        if key in index:
            continue
        f = fb.RangeFile(f"{fb.BUCKET}/{key}", size, block=1 << 20)
        md = pq.ParquetFile(f).metadata
        names = {md.schema.column(i).path: i for i in range(md.num_columns)}
        cols = [names["bbox.xmin"], names["bbox.xmax"], names["bbox.ymin"], names["bbox.ymax"]]
        groups = []
        for g in range(md.num_row_groups):
            rg = md.row_group(g)
            st = [rg.column(c).statistics for c in cols]
            if any(s is None or not s.has_min_max for s in st):
                groups.append(None)
                continue
            groups.append([st[0].min, st[1].max, st[2].min, st[3].max])
        index[key] = {"size": size, "groups": groups}
        dirty += 1
        print(f"  footer {n + 1}/{len(files)} {md.num_row_groups} groups ({f.fetched >> 10} KiB)", file=sys.stderr, flush=True)
        if dirty % 16 == 0:
            json.dump(index, open(path, "w"))
    if dirty:
        json.dump(index, open(path, "w"))
    return [(k, index[k]["size"], index[k]["groups"]) for k, _ in files]


def linestring(wkb):
    e = "<" if wkb[0] == 1 else ">"
    t, = struct.unpack_from(e + "I", wkb, 1)
    if t & 0xFF != 2:
        raise ValueError(f"WKB type {t}")
    n, = struct.unpack_from(e + "I", wkb, 5)
    pts = struct.unpack_from(e + f"{2 * n}d", wkb, 9)
    return [(pts[2 * j], pts[2 * j + 1]) for j in range(n)]


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
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    mlat = 111_132.0
    mlon = 111_320.0 * math.cos(math.radians(a.lat))
    dlat, dlon = a.half_km * 1000 / mlat, a.half_km * 1000 / mlon
    box = (a.lon - dlon, a.lon + dlon, a.lat - dlat, a.lat + dlat)
    index = footer_index(a.release, a.cache)
    wanted = ["geometry", "bbox", "sources", "subtype", "class", "subclass", "road_surface", "road_flags"]
    out = bytearray(b"SFR1") + struct.pack("<ddI", a.lat, a.lon, 0)
    count = skipped = 0
    for key, size, groups in index:
        hit = [g for g, b in enumerate(groups) if b is None or not (b[1] < box[0] or b[0] > box[1] or b[3] < box[2] or b[2] > box[3])]
        if not hit:
            continue
        f = fb.RangeFile(f"{fb.BUCKET}/{key}", size, block=4 << 20)
        pf = pq.ParquetFile(f)
        cols = [c for c in wanted if c in set(pf.schema_arrow.names)]
        for g in hit:
            for r in pf.read_row_group(g, columns=cols).to_pylist():
                bb = r["bbox"]
                if bb["xmax"] < box[0] or bb["xmin"] > box[1] or bb["ymax"] < box[2] or bb["ymin"] > box[3]:
                    continue
                if (r.get("subtype") or "") != "road":
                    continue
                cls = (r.get("class") or "").lower()
                if cls not in CLASSES:
                    continue
                sub = (r.get("subclass") or "").lower()
                if sub in ("driveway", "sidewalk", "crosswalk", "cycle_crossing"):
                    continue
                src = r.get("sources") or []
                if not src or (src[0].get("dataset") or "") != "OpenStreetMap":
                    skipped += 1
                    continue
                try:
                    line = linestring(r["geometry"])
                except Exception:
                    continue
                flags = (1 if sub == "link" else 0) | (2 if flagged(r.get("road_flags"), "is_bridge") else 0) \
                    | (4 if flagged(r.get("road_flags"), "is_tunnel") else 0)
                surf = r.get("road_surface") or []
                if any((s.get("value") or "") in UNPAVED and not s.get("between") for s in surf):
                    flags |= 8
                pts = [(round((lo - a.lon) * mlon * 10), round((la - a.lat) * mlat * 10)) for lo, la in line]
                ded = [pts[0]]
                for p in pts[1:]:
                    # Steps longer than an i16 of decimetres are split.
                    while max(abs(p[0] - ded[-1][0]), abs(p[1] - ded[-1][1])) > 30_000:
                        q = ded[-1]
                        k = 30_000 / max(abs(p[0] - q[0]), abs(p[1] - q[1]))
                        ded.append((q[0] + round((p[0] - q[0]) * k), q[1] + round((p[1] - q[1]) * k)))
                    if p != ded[-1]:
                        ded.append(p)
                if len(ded) < 2 or len(ded) > 60_000:
                    continue
                out += struct.pack("<BBHii", CLASSES.index(cls), flags, len(ded), ded[0][0], ded[0][1])
                for p, q in zip(ded[1:], ded[:-1]):
                    out += struct.pack("<hh", p[0] - q[0], p[1] - q[1])
                count += 1
            print(f"  {os.path.basename(key)[:10]} group {g}: {count} kept ({f.fetched >> 20} MiB)", file=sys.stderr, flush=True)
    struct.pack_into("<I", out, 20, count)
    with open(a.out, "wb") as fh:
        fh.write(out)
    print(f"{a.out}: {count} roads, {len(out)} bytes ({skipped} non-OSM records dropped)")


if __name__ == "__main__":
    main()
