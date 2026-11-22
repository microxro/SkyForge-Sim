#!/usr/bin/env python3
"""SKYFORGE build-time helpers shared by the Overture Maps fetch tools (buildings, land use).

Overture Maps Foundation public bucket on AWS Open Data (no key, no account). Parquet footers are read by
HTTP range and cached as a row-group bounding-box index, so a region fetch downloads only the row groups
that intersect its box.
"""
import io, json, math, os, struct, sys, time, re
import requests

BUCKET = "https://overturemaps-us-west-2.s3.amazonaws.com"
SESSION = requests.Session()


def region_box(lat, lon, half_km):
    """(lon_min, lon_max, lat_min, lat_max, metres_per_deg_lat, metres_per_deg_lon)."""
    mlat = 111_132.0
    mlon = 111_320.0 * math.cos(math.radians(lat))
    dlat, dlon = half_km * 1000 / mlat, half_km * 1000 / mlon
    return (lon - dlon, lon + dlon, lat - dlat, lat + dlat, mlat, mlon)


def row_groups_in_box(index, box):
    """Yield (key, size, group) for every row group whose bbox intersects box (lon0, lon1, lat0, lat1)."""
    for key, size, groups in index:
        hit = [g for g, b in enumerate(groups) if b is None or not (b[1] < box[0] or b[0] > box[1] or b[3] < box[2] or b[2] > box[3])]
        if hit: yield key, size, hit


def parse_sources(arg):
    """--sources value -> allow-list set, or None for "any" (keep everything). Empty input falls back to OSM only."""
    if arg.strip().lower() == "any": return None
    return {x.strip() for x in arg.split(",") if x.strip()} or {"OpenStreetMap"}


def source_allowed(rec, allow):
    return allow is None or source_dataset(rec) in allow


def source_dataset(rec):
    src = rec.get("sources") or []
    return (src[0].get("dataset") or "") if src else ""


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


def list_files(release, theme="buildings", typ="building"):
    keys, token = [], None
    while True:
        url = f"{BUCKET}/?list-type=2&prefix=release/{release}/theme={theme}/type={typ}/&max-keys=1000"
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


def footer_index(release, cache_dir, theme="buildings", typ="building"):
    """[(key, size, [(xmin, xmax, ymin, ymax) per row group])], cached on disk."""
    import pyarrow.parquet as pq
    path = os.path.join(cache_dir, f"overture-{theme}-{typ}-{release}.index.json" if (theme, typ) != ("buildings", "building") else f"overture-buildings-{release}.index.json")
    index = json.load(open(path)) if os.path.exists(path) else {}
    files = list_files(release, theme, typ)
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


def dedup_split(pts, limit=30_000):
    """Drop repeated points and split any step longer than `limit` (decimetres, Chebyshev) into equal-ish pieces so
    every delta fits an i16."""
    ded = [pts[0]] if pts else []
    for p in pts[1:]:
        while max(abs(p[0] - ded[-1][0]), abs(p[1] - ded[-1][1])) > limit:
            q = ded[-1]
            k = limit / max(abs(p[0] - q[0]), abs(p[1] - q[1]))
            ded.append((q[0] + round((p[0] - q[0]) * k), q[1] + round((p[1] - q[1]) * k)))
        if p != ded[-1]: ded.append(p)
    return ded


def polygons(wkb):
    """Outer rings (lon, lat lists) of a WKB Polygon / MultiPolygon (little- or big-endian; ISO or EWKB Z/SRID flags
    tolerated, Z/M ordinates dropped). Holes are ignored."""
    out = []

    def read(b, o):
        e = "<" if b[o] == 1 else ">"
        t, = struct.unpack_from(e + "I", b, o + 1)
        o += 5
        dims = 2 + (1 if (t & 0x80000000 or 1000 <= (t & 0xFFFF) < 2000 or 3000 <= (t & 0xFFFF) < 4000) else 0) \
                 + (1 if (t & 0x40000000 or 2000 <= (t & 0xFFFF) < 4000) else 0)
        if t & 0x20000000: o += 4                       # EWKB SRID
        t = (t & 0xFFFF) % 1000
        if t == 3:
            n, = struct.unpack_from(e + "I", b, o); o += 4
            for i in range(n):
                m, = struct.unpack_from(e + "I", b, o); o += 4
                pts = struct.unpack_from(e + f"{dims * m}d", b, o); o += 8 * dims * m
                if i == 0: out.append([(pts[dims * j], pts[dims * j + 1]) for j in range(m)])
            return o
        if t == 6:
            n, = struct.unpack_from(e + "I", b, o); o += 4
            for _ in range(n): o = read(b, o)
            return o
        raise ValueError(f"WKB type {t}")

    read(wkb, 0)
    return out
