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

Usage: fetch_buildings.py --lat 47.53 --lon -122.30 --half-km 6 --out KBFI/buildings.sfb [--release 2026-10-21.0]
"""
import argparse, io, json, math, os, struct, sys, time, re
import requests

BUCKET = "https://overturemaps-us-west-2.s3.amazonaws.com"
SESSION = requests.Session()
KINDS = ["yes", "house", "residential", "apartments", "commercial", "industrial", "retail", "office", "warehouse",
         "hangar", "garage", "shed", "church", "school", "hospital", "hotel", "civic", "transportation", "roof",
         "agricultural", "service", "religious", "education", "medical", "entertainment", "military", "outbuilding"]
ROOFS = ["", "flat", "gabled", "hipped", "pyramidal", "skillion", "gambrel", "mansard", "dome", "round", "onion", "saltbox",
         "half_hipped", "sawtooth", "cone", "spherical"]


class RangeFile(io.RawIOBase):
    """Seekable read-only file over HTTP range requests with a small block cache."""

    def __init__(self, url, size, block=1 << 20):
        self.url, self.size, self.pos, self.block, self.cache, self.fetched = url, size, 0, block, {}, 0

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else (self.pos + off if whence == 1 else self.size + off)
        return self.pos

    def _get(self, a, b):
        for attempt in range(5):
            try:
                r = SESSION.get(self.url, headers={"Range": f"bytes={a}-{b - 1}"}, timeout=120)
                if r.status_code in (200, 206):
                    self.fetched += len(r.content)
                    return r.content
            except requests.RequestException:
                pass
            time.sleep(1.5 * (attempt + 1))
        raise IOError(f"range request failed: {self.url} {a}-{b}")

    def read(self, n=-1):
        if n < 0: n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n <= 0: return b""
        a, b = self.pos, self.pos + n
        if n > 4 * self.block:                      # a whole column chunk: one request
            data = self._get(a, b)
        else:
            out = bytearray()
            k0, k1 = a // self.block, (b - 1) // self.block
            missing = [k for k in range(k0, k1 + 1) if k not in self.cache]
            if missing:
                m0, m1 = missing[0], missing[-1]
                blob = self._get(m0 * self.block, min(self.size, (m1 + 1) * self.block))
                for k in range(m0, m1 + 1):
                    self.cache[k] = blob[(k - m0) * self.block:(k - m0 + 1) * self.block]
            for k in range(k0, k1 + 1): out += self.cache[k]
            data = bytes(out[a - k0 * self.block:b - k0 * self.block])
        self.pos = b
        return data

    def readinto(self, buf):
        d = self.read(len(buf)); buf[:len(d)] = d; return len(d)


def list_files(release):
    keys, token = [], None
    while True:
        url = f"{BUCKET}/?list-type=2&prefix=release/{release}/theme=buildings/type=building/&max-keys=1000"
        if token: url += "&continuation-token=" + requests.utils.quote(token)
        x = SESSION.get(url, timeout=60).text
        for m in re.finditer(r"<Contents>(.*?)</Contents>", x, re.S):
            k = re.search(r"<Key>([^<]+)</Key>", m.group(1)).group(1)
            s = int(re.search(r"<Size>(\d+)</Size>", m.group(1)).group(1))
            if k.endswith(".parquet"): keys.append((k, s))
        t = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", x)
        if not t: break
        token = t.group(1)
    return keys


def footer_index(release, cache_dir):
    """[(key, size, [(xmin, xmax, ymin, ymax) per row group])], cached on disk."""
    import pyarrow.parquet as pq
    path = os.path.join(cache_dir, f"overture-buildings-{release}.index.json")
    index = json.load(open(path)) if os.path.exists(path) else {}
    files = list_files(release)
    dirty = 0
    for n, (key, size) in enumerate(files):
        if key in index: continue
        f = RangeFile(f"{BUCKET}/{key}", size, block=1 << 20)
        md = pq.ParquetFile(f).metadata
        names = {md.schema.column(i).path: i for i in range(md.num_columns)}
        cols = [names["bbox.xmin"], names["bbox.xmax"], names["bbox.ymin"], names["bbox.ymax"]]
        groups = []
        for g in range(md.num_row_groups):
            rg = md.row_group(g)
            st = [rg.column(c).statistics for c in cols]
            if any(s is None or not s.has_min_max for s in st): groups.append(None); continue
            groups.append([st[0].min, st[1].max, st[2].min, st[3].max])
        index[key] = {"size": size, "groups": groups}
        dirty += 1
        print(f"  footer {n + 1}/{len(files)} {md.num_row_groups} groups ({f.fetched >> 10} KiB)", file=sys.stderr, flush=True)
        if dirty % 16 == 0: json.dump(index, open(path, "w"))
    if dirty: json.dump(index, open(path, "w"))
    return [(k, index[k]["size"], index[k]["groups"]) for k, _ in files]


def polygons(wkb):
    """Outer rings (lon, lat lists) of a WKB Polygon / MultiPolygon (little- or big-endian)."""
    out = []

    def read(b, o):
        e = "<" if b[o] == 1 else ">"
        t, = struct.unpack_from(e + "I", b, o + 1)
        t &= 0xFF
        o += 5
        if t == 3:
            n, = struct.unpack_from(e + "I", b, o); o += 4
            for i in range(n):
                m, = struct.unpack_from(e + "I", b, o); o += 4
                pts = struct.unpack_from(e + f"{2 * m}d", b, o); o += 16 * m
                if i == 0: out.append([(pts[2 * j], pts[2 * j + 1]) for j in range(m)])
            return o
        if t == 6:
            n, = struct.unpack_from(e + "I", b, o); o += 4
            for _ in range(n): o = read(b, o)
            return o
        raise ValueError(f"WKB type {t}")

    read(wkb, 0)
    return out


def colour(s):
    if not s: return (0, 0, 0)
    s = s.strip().lower()
    if s.startswith("#") and len(s) == 7:
        try: return tuple(max(1, int(s[i:i + 2], 16)) for i in (1, 3, 5))
        except ValueError: return (0, 0, 0)
    return (0, 0, 0)


def main():
    import pyarrow.parquet as pq
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True); ap.add_argument("--lon", type=float, required=True)
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
    wanted = ["geometry", "bbox", "sources", "subtype", "class", "height", "num_floors", "min_height", "roof_shape",
              "roof_color", "facade_color", "roof_height", "has_parts", "is_underground"]
    rows, kept, skipped_src = [], 0, 0
    for key, size, groups in index:
        hit = [g for g, b in enumerate(groups) if b is None or not (b[1] < box[0] or b[0] > box[1] or b[3] < box[2] or b[2] > box[3])]
        if not hit: continue
        f = RangeFile(f"{BUCKET}/{key}", size, block=4 << 20)
        pf = pq.ParquetFile(f)
        have = set(pf.schema_arrow.names)
        cols = [c for c in wanted if c in have]
        for g in hit:
            t = pf.read_row_group(g, columns=cols).to_pylist()
            for r in t:
                bb = r["bbox"]
                if bb["xmax"] < box[0] or bb["xmin"] > box[1] or bb["ymax"] < box[2] or bb["ymin"] > box[3]: continue
                src = r.get("sources") or []
                if not src or (src[0].get("dataset") or "") != "OpenStreetMap": skipped_src += 1; continue
                if r.get("is_underground"): continue
                rows.append(r); kept += 1
            print(f"  {os.path.basename(key)[:10]} group {g}: {kept} kept ({f.fetched >> 20} MiB)", file=sys.stderr, flush=True)
    out = bytearray(b"SFB1") + struct.pack("<ddI", a.lat, a.lon, 0)
    count = 0
    for r in rows:
        try: rings = polygons(r["geometry"])
        except Exception: continue
        kind = (r.get("class") or r.get("subtype") or "yes").lower()
        ki = KINDS.index(kind) if kind in KINDS else 0
        ro = (r.get("roof_shape") or "").lower()
        ri = ROOFS.index(ro) if ro in ROOFS else 0
        h = r.get("height"); floors = r.get("num_floors"); mh = r.get("min_height") or 0
        flags = (1 if h else 0) | (2 if r.get("has_parts") else 0)
        hd = int(max(0, min(65535, round((h or 0) * 10))))
        rc, wc = colour(r.get("roof_color")), colour(r.get("facade_color"))
        for ring in rings:
            pts = [(round((lo - a.lon) * mlon * 10), round((la - a.lat) * mlat * 10)) for lo, la in ring]
            if len(pts) > 1 and pts[0] == pts[-1]: pts = pts[:-1]
            ded = [pts[0]] if pts else []
            for p in pts[1:]:
                if p != ded[-1]: ded.append(p)
            if len(ded) < 3 or len(ded) > 4000: continue
            if any(abs(ded[i][0] - ded[i - 1][0]) > 32767 or abs(ded[i][1] - ded[i - 1][1]) > 32767 for i in range(1, len(ded))): continue
            out += struct.pack("<iiHHBBBB3B3BH", ded[0][0], ded[0][1], hd, int(max(0, min(65535, round(mh * 10)))), ki, ri,
                               int(max(0, min(255, floors or 0))), flags, *rc, *wc, len(ded))
            for i in range(1, len(ded)):
                out += struct.pack("<hh", ded[i][0] - ded[i - 1][0], ded[i][1] - ded[i - 1][1])
            count += 1
    struct.pack_into("<I", out, 20, count)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "wb").write(out)
    print(f"{a.out}: {count} footprints, {len(out) >> 10} KiB; {skipped_src} non-OSM records skipped", file=sys.stderr)


if __name__ == "__main__":
    main()
