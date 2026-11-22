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
import argparse, json, math, os, re, struct, sys
import io, time
import requests

# Self-contained (range-request reader and WKB polygon parser as in tools/fetch_buildings.py).
BUCKET = "https://overturemaps-us-west-2.s3.amazonaws.com"
SESSION = requests.Session()


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



RELEASE = "2026-10-21.0"
SURFACE = {"boundary": 0, "apron": 1, "taxiway": 2, "runway": 3}
DEFAULT_WIDTH_M = {"runway": 30.0, "taxiway": 15.0, "apron": 20.0}
MASK_VALUE = {0: 0.10, 1: 0.33, 2: 0.66, 3: 1.0}


def width_of(r):
    """Paved width (m) from the OSM `width` tag carried in source_tags (list of (key, value) or a dict); 0 = unknown, and the
    renderer then uses the primary runway's own width or its per-surface default (runway 30 m, taxiway 15 m)."""
    tags = r.get("source_tags") or {}
    items = tags.items() if isinstance(tags, dict) else tags
    for k, v in items:
        if k in ("width", "aeroway:width"):
            try: return max(0.0, min(150.0, float(str(v).split()[0].replace(",", "."))))
            except ValueError: return 0.0
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


def list_files(theme_type):
    out = []
    x = SESSION.get(f"{BUCKET}/?list-type=2&prefix=release/{RELEASE}/theme={theme_type}/", timeout=60).text
    for m in re.finditer(r"<Contents>(.*?)</Contents>", x, re.S):
        k = re.search(r"<Key>([^<]+)</Key>", m.group(1)).group(1)
        s = int(re.search(r"<Size>(\d+)</Size>", m.group(1)).group(1))
        if k.endswith(".parquet"): out.append((k, s))
    return out


def footer_index(theme_type, cache_dir):
    import pyarrow.parquet as pq
    path = os.path.join(cache_dir, f"overture-{theme_type.replace('/', '-').replace('=', '')}-{RELEASE}.index.json")
    index = json.load(open(path)) if os.path.exists(path) else {}
    files = list_files(theme_type)
    for n, (key, size) in enumerate(files):
        if key in index: continue
        f = RangeFile(f"{BUCKET}/{key}", size, block=1 << 20)
        md = pq.ParquetFile(f).metadata
        names = {md.schema.column(i).path: i for i in range(md.num_columns)}
        cols = [names[c] for c in ("bbox.xmin", "bbox.xmax", "bbox.ymin", "bbox.ymax")]
        groups = []
        for g in range(md.num_row_groups):
            rg = md.row_group(g)
            st = [rg.column(c).statistics for c in cols]
            groups.append(None if any(s is None or not s.has_min_max for s in st) else [st[0].min, st[1].max, st[2].min, st[3].max])
        index[key] = {"size": size, "groups": groups}
        print(f"  footer {theme_type} {n + 1}/{len(files)} ({f.fetched >> 10} KiB)", file=sys.stderr, flush=True)
        json.dump(index, open(path, "w"))
    return [(k, index[k]["size"], index[k]["groups"]) for k, _ in files]


def lines(wkb):
    """Vertex lists (lon, lat) of a WKB LineString / MultiLineString."""
    out = []

    def read(b, o):
        e = "<" if b[o] == 1 else ">"
        t, = struct.unpack_from(e + "I", b, o + 1); t &= 0xFF; o += 5
        if t == 2:
            n, = struct.unpack_from(e + "I", b, o); o += 4
            pts = struct.unpack_from(e + f"{2 * n}d", b, o); o += 16 * n
            out.append([(pts[2 * j], pts[2 * j + 1]) for j in range(n)])
            return o
        if t == 5:
            n, = struct.unpack_from(e + "I", b, o); o += 4
            for _ in range(n): o = read(b, o)
            return o
        return None   # not a line

    read(wkb, 0)
    return out


def geom_kind(wkb):
    t = struct.unpack_from("<I" if wkb[0] == 1 else ">I", wkb, 1)[0] & 0xFF
    return "line" if t in (2, 5) else ("polygon" if t in (3, 6) else None)


def scan(theme_type, box, cache, want, all_sources):
    import pyarrow.parquet as pq
    rows, dropped = [], 0
    for key, size, groups in footer_index(theme_type, cache):
        hit = [g for g, b in enumerate(groups) if b is None or not (b[1] < box[0] or b[0] > box[1] or b[3] < box[2] or b[2] > box[3])]
        if not hit: continue
        f = RangeFile(f"{BUCKET}/{key}", size, block=4 << 20)
        pf = pq.ParquetFile(f)
        cols = [c for c in ("geometry", "bbox", "sources", "subtype", "class", "surface", "source_tags") if c in pf.schema_arrow.names]
        for g in hit:
            for r in pf.read_row_group(g, columns=cols).to_pylist():
                bb = r["bbox"]
                if bb["xmax"] < box[0] or bb["xmin"] > box[1] or bb["ymax"] < box[2] or bb["ymin"] > box[3]: continue
                if not want(r): continue
                src = r.get("sources") or []
                if not all_sources and (not src or (src[0].get("dataset") or "") != "OpenStreetMap"): dropped += 1; continue
                rows.append(r)
    return rows, dropped


def surface_of(cls):
    cls = (cls or "").lower()
    if cls == "runway": return "runway"
    if cls.endswith("airport") or cls in ("aerodrome", "airfield", "airstrip"): return "boundary"   # e.g. regional_airport polygon
    if cls == "apron": return "apron"
    return "taxiway"     # taxiway, taxilane, helipad, parking positions, holding positions, ...


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True); ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half-km", type=float, default=3.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--all-sources", action="store_true", help="keep non-OSM Overture sources (NOT the project default; see DECISIONS.md)")
    ap.add_argument("--survey", action="store_true", help="print class histograms of airport-related rows and exit")
    ap.add_argument("--png", help="also write the rasterised r8 mask (north up) to this PNG")
    ap.add_argument("--png-size", type=int, default=2048)
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/skyforge-overture"))
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    mlat = 111_132.0; mlon = 111_320.0 * math.cos(math.radians(a.lat))
    dlat, dlon = a.half_km * 1000 / mlat, a.half_km * 1000 / mlon
    box = (a.lon - dlon, a.lon + dlon, a.lat - dlat, a.lat + dlat)

    infra, d1 = scan("base/type=infrastructure", box, a.cache, lambda r: (r.get("subtype") or "") == "airport", a.all_sources)
    if a.survey:
        from collections import Counter
        print("infrastructure/airport classes:", Counter((r.get("class"), geom_kind(r["geometry"])) for r in infra))
        return

    out = bytearray(b"SFA1") + struct.pack("<ddI", a.lat, a.lon, 0)
    counts = {}
    def emit(surface, kind, width_m, pts, unpaved=False):
        nonlocal out
        q = [(round((lo - a.lon) * mlon * 10), round((la - a.lat) * mlat * 10)) for lo, la in pts]
        if kind == "polygon" and len(q) > 1 and q[0] == q[-1]: q = q[:-1]
        ded = [q[0]] if q else []
        for p in q[1:]:
            if p != ded[-1]: ded.append(p)
        if len(ded) < (3 if kind == "polygon" else 2) or len(ded) > 20000: return
        if any(abs(ded[i][0] - ded[i - 1][0]) > 32767 or abs(ded[i][1] - ded[i - 1][1]) > 32767 for i in range(1, len(ded))): return
        out += struct.pack("<BBHHii", SURFACE[surface], (0 if kind == "polygon" else 1) | (2 if unpaved else 0), int(round(width_m * 10)), len(ded), *ded[0])
        for i in range(1, len(ded)): out += struct.pack("<hh", ded[i][0] - ded[i - 1][0], ded[i][1] - ded[i - 1][1])
        counts[(surface, kind)] = counts.get((surface, kind), 0) + 1

    for r in infra:
        s = surface_of(r.get("class")); k = geom_kind(r["geometry"])
        if k == "polygon":
            for ring in polygons(r["geometry"]): emit(s, "polygon", 0, ring, is_unpaved(r))
        elif k == "line":
            for ln in lines(r["geometry"]): emit(s, "line", width_of(r), ln, is_unpaved(r))
    n = sum(counts.values())
    struct.pack_into("<I", out, 20, n)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    open(a.out, "wb").write(out)
    print(f"{a.out}: {n} features {dict(counts)}, {len(out)} B; {d1} non-OSM records skipped", file=sys.stderr)

    if a.png:
        from PIL import Image, ImageDraw
        S = a.png_size; px = 2 * a.half_km * 1000 / S
        img = Image.new("L", (S, S), 0); dr = ImageDraw.Draw(img)
        def to_px(lon, lat): return ((lon - a.lon) * mlon / px + S / 2, S / 2 - (lat - a.lat) * mlat / px)
        items = []
        for r in infra:
            if is_unpaved(r): continue                  # unpaved strips are infield, not pavement
            s = SURFACE[surface_of(r.get("class"))]; k = geom_kind(r["geometry"])
            if k == "polygon": items += [(s, "polygon", 0, ring) for ring in polygons(r["geometry"])]
            elif k == "line": items += [(s, "line", width_of(r) or DEFAULT_WIDTH_M.get(surface_of(r.get("class")), 15.0), ln) for ln in lines(r["geometry"])]
        for s, k, w, pts in sorted(items, key=lambda t: (t[0] == 3, t[0])):   # runway last (on top); boundary first
            v = int(MASK_VALUE[s] * 255); p = [to_px(*q) for q in pts]
            if k == "polygon": dr.polygon(p, fill=v)
            else: dr.line(p, fill=v, width=max(1, round(w / px)))
        img.save(a.png); print(f"{a.png}: {S}² at {px:.2f} m/px", file=sys.stderr)


if __name__ == "__main__":
    main()
