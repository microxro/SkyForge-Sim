#!/usr/bin/env python3
"""SKYFORGE build-time helpers shared by the Overture Maps fetch tools (buildings, roads, land use, airport surfaces).

Overture Maps Foundation public bucket on AWS Open Data (no key, no account). Parquet footers are read by
HTTP range and cached as a row-group bounding-box index, so a region fetch downloads only the row groups
that intersect its box.

Hardening rules every tool relies on (see docs/rounds/ROUND2.md):
  * a listing, footer or range request that fails raises (FetchError / IOError); it never degrades into an empty result;
  * an output that would be empty never replaces an existing file unless --allow-empty is given (write_output);
  * geometry parsers raise ValueError (never struct.error / IndexError / RecursionError) on malformed bytes, and
    non-finite or out-of-range coordinates are rejected before they reach `round()` or `struct.pack`;
  * index caches are written atomically and a corrupt cache is rebuilt, not trusted.
"""
import io, json, math, os, struct, sys, tempfile, time
import xml.etree.ElementTree as ET
import requests

from _net import MAX_BYTES

BUCKET = "https://overturemaps-us-west-2.s3.amazonaws.com"
SESSION = requests.Session()
MAX_LIST_PAGES = 200            # 200 x 1000 keys; the whole buildings theme is a few hundred files
MAX_WKB_DEPTH = 3               # Multi* > polygon/line is two levels; one spare
INT32_DM = 2 ** 31 - 1          # decimetre coordinates must fit an i32 (about 214 km)


class FetchError(RuntimeError):
    """A network or listing failure that must stop the run (so no empty output replaces a good one)."""


# ---------------------------------------------------------------------------------------------------------------
# Region and filters
# ---------------------------------------------------------------------------------------------------------------

def region_box(lat, lon, half_km):
    """(lon_min, lon_max, lat_min, lat_max, metres_per_deg_lat, metres_per_deg_lon). Raises ValueError for a centre
    that is not finite, lies beyond +-85 deg latitude (cos(lat) tends to 0), whose half extent is not in (0, 200] km,
    or whose box crosses the antimeridian or a pole (the bbox index compares plain min/max, so it would silently match
    nothing)."""
    for name, v in (("lat", lat), ("lon", lon), ("half-km", half_km)):
        if not isinstance(v, (int, float)) or not math.isfinite(v): raise ValueError(f"{name} must be a finite number")
    if not -85.0 <= lat <= 85.0: raise ValueError("lat must be within +-85 degrees")
    if not -180.0 <= lon <= 180.0: raise ValueError("lon must be within +-180 degrees")
    if not 0.0 < half_km <= 200.0: raise ValueError("half-km must be in (0, 200]")
    mlat = 111_132.0
    mlon = 111_320.0 * math.cos(math.radians(lat))
    dlat, dlon = half_km * 1000 / mlat, half_km * 1000 / mlon
    if lon - dlon < -180.0 or lon + dlon > 180.0:
        raise ValueError("the box crosses the antimeridian; fetch it as two regions")
    if lat - dlat < -90.0 or lat + dlat > 90.0:
        raise ValueError("the box crosses a pole")
    return (lon - dlon, lon + dlon, lat - dlat, lat + dlat, mlat, mlon)


def box_or_exit(ap, lat, lon, half_km):
    """region_box for a tool's main(): a bad argument ends the run through argparse's usage error."""
    try: return region_box(lat, lon, half_km)
    except ValueError as e: ap.error(str(e))


def fnum(v, default=None):
    """float(v) when it is a finite number, else default (NaN, inf, strings, None)."""
    try: x = float(v)
    except (TypeError, ValueError): return default
    return x if math.isfinite(x) else default


def row_bbox_hit(r, box):
    """True when the record's bbox struct intersects box (lon0, lon1, lat0, lat1), False when it does not, and None when
    the bbox is missing or malformed (callers count those rows as skipped instead of crashing)."""
    bb = r.get("bbox") if isinstance(r, dict) else None
    if not isinstance(bb, dict): return None
    xs = [fnum(bb.get(k)) for k in ("xmin", "xmax", "ymin", "ymax")]
    if any(v is None for v in xs): return None
    return not (xs[1] < box[0] or xs[0] > box[1] or xs[3] < box[2] or xs[2] > box[3])


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
    first = src[0] if src and isinstance(src[0], dict) else {}
    return first.get("dataset") or ""


# ---------------------------------------------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------------------------------------------

class RangeFile(io.RawIOBase):
    """Seekable read-only file over HTTP range requests with a small block cache. Only a 206 answer of exactly the
    requested length is accepted (a 200 means the server ignored Range and would return the whole object); 4xx answers
    other than 408/429 fail at once instead of being retried; network errors and 5xx are retried with back-off."""

    def __init__(self, url, size, block=1 << 20):
        self.url, self.size, self.pos, self.block, self.cache, self.fetched = url, size, 0, block, {}, 0

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else (self.pos + off if whence == 1 else self.size + off)
        return self.pos

    def _get(self, a, b):
        want = b - a
        if want <= 0 or want > MAX_BYTES:
            raise ValueError(f"refusing range request of {want} bytes")
        last = "no response"
        for attempt in range(5):
            try:
                r = SESSION.get(self.url, headers={"Range": f"bytes={a}-{b - 1}"}, timeout=120, stream=True)
            except requests.RequestException as e:
                last = f"{type(e).__name__}"
            else:
                try:
                    if r.status_code == 206:
                        cr = r.headers.get("Content-Range", "")
                        if not cr.startswith(f"bytes {a}-{b - 1}/"):
                            raise IOError(f"bad Content-Range {cr!r} for {self.url} {a}-{b}")
                        body = r.raw.read(want + 1, decode_content=True)     # bounded: never more than want + 1 bytes
                        if len(body) == want:
                            self.fetched += want
                            return body
                        last = f"HTTP 206, {len(body)} of {want} bytes"
                    elif r.status_code == 200:
                        raise IOError(f"server ignored the Range header (200): {self.url}")
                    elif 400 <= r.status_code < 500 and r.status_code not in (408, 429):
                        raise IOError(f"range request refused (HTTP {r.status_code}): {self.url} {a}-{b}")
                    else:
                        last = f"HTTP {r.status_code}"
                finally:
                    r.close()
            time.sleep(1.5 * (attempt + 1))
        raise IOError(f"range request failed ({last}): {self.url} {a}-{b}")

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
    """[(key, size)] of every .parquet under release/<release>/theme=<theme>/type=<typ>/. Follows continuation tokens
    and raises FetchError on a non-200 answer, an S3 <Error> document, a repeated token, or an empty result (a wrong
    release or theme must not look like "no data")."""
    keys, token, seen = [], None, set()
    for _ in range(MAX_LIST_PAGES):
        url = f"{BUCKET}/?list-type=2&prefix=release/{release}/theme={theme}/type={typ}/&max-keys=1000"
        if token: url += "&continuation-token=" + requests.utils.quote(token)
        try: r = SESSION.get(url, timeout=60)
        except requests.RequestException as e: raise FetchError(f"listing failed: {type(e).__name__}") from e
        if r.status_code != 200: raise FetchError(f"listing failed: HTTP {r.status_code} for {url}")
        try: root = ET.fromstring(r.content)            # parsed, not pattern-matched (as the security pass did for the tools)
        except ET.ParseError as e: raise FetchError(f"listing is not valid XML for {url}") from e
        ns = root.tag.partition("}")[0] + "}" if root.tag.startswith("{") else ""
        if root.tag != ns + "ListBucketResult": raise FetchError(f"listing returned an error document for {url}")
        for c in root.iter(ns + "Contents"):
            k, sz = c.findtext(ns + "Key"), c.findtext(ns + "Size")
            if not k or not sz or not sz.isdigit(): raise FetchError(f"malformed <Contents> entry in listing of {url}")
            if k.endswith(".parquet"): keys.append((k, int(sz)))
        t = root.findtext(ns + "NextContinuationToken")
        if not t: break
        if t in seen: raise FetchError("listing continuation token repeated")
        seen.add(t); token = t
    else:
        raise FetchError(f"listing exceeded {MAX_LIST_PAGES} pages")
    if not keys: raise FetchError(f"no parquet files under release {release} theme={theme}/type={typ} (wrong release?)")
    return keys


def load_index_cache(path):
    """The cached footer index, or {} when the file is missing, unreadable, truncated or not a JSON object."""
    try:
        with open(path) as fh: data = json.load(fh)
    except (OSError, ValueError): return {}
    return data if isinstance(data, dict) else {}


def atomic_write(path, data):
    """Write bytes or str to path through a temp file in the same directory and os.replace (readers never see a
    half-written file; a crash leaves the old one)."""
    d = os.path.dirname(os.path.abspath(path)); os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=os.path.basename(path) + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data.encode() if isinstance(data, str) else data)
            fh.flush(); os.fsync(fh.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise


def save_index_cache(path, index):
    atomic_write(path, json.dumps(index))


def _valid_entry(e, size):
    if not isinstance(e, dict) or e.get("size") != size: return False
    g = e.get("groups")
    return isinstance(g, list) and all(b is None or (isinstance(b, list) and len(b) == 4 and all(fnum(v) is not None for v in b)) for b in g)


def footer_index(release, cache_dir, theme="buildings", typ="building"):
    """[(key, size, [(xmin, xmax, ymin, ymax) per row group])], cached on disk. A cached entry is reused only when its
    recorded size equals the listed object's size; anything else is fetched again."""
    import pyarrow.parquet as pq
    path = os.path.join(cache_dir, f"overture-{theme}-{typ}-{release}.index.json" if (theme, typ) != ("buildings", "building") else f"overture-buildings-{release}.index.json")
    index = load_index_cache(path)
    files = list_files(release, theme, typ)
    dirty = 0
    for n, (key, size) in enumerate(files):
        if _valid_entry(index.get(key), size): continue
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
        if dirty % 16 == 0: save_index_cache(path, index)
    if dirty: save_index_cache(path, index)
    return [(k, index[k]["size"], index[k]["groups"]) for k, _ in files]


# ---------------------------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------------------------

def write_output(path, data, count, allow_empty=False):
    """Atomically write a pack. A zero-count result (a failed listing, a wrong box, a filter that dropped everything)
    must not replace an existing file: it exits with status 2 (message on stderr) unless allow_empty. With no existing file an empty pack
    is written with a warning."""
    if count == 0 and not allow_empty:
        if os.path.exists(path):
            print(f"error: {path}: refusing to overwrite the existing file with an empty result (0 records); "
                  "check the region and --sources, or pass --allow-empty", file=sys.stderr)
            raise SystemExit(2)
        print(f"WARNING: {path}: 0 records written", file=sys.stderr)
    atomic_write(path, bytes(data))


# ---------------------------------------------------------------------------------------------------------------
# Coordinates
# ---------------------------------------------------------------------------------------------------------------

def project_ring(pts, lat0, lon0, mlat, mlon):
    """[(lon, lat)] -> [(x_dm, y_dm)] east/north of (lat0, lon0), or None if any ordinate is not finite or the result
    does not fit an i32 decimetre coordinate."""
    out = []
    for p in pts:
        lo, la = fnum(p[0]), fnum(p[1])
        if lo is None or la is None: return None
        x, y = (lo - lon0) * mlon * 10, (la - lat0) * mlat * 10
        if abs(x) > INT32_DM or abs(y) > INT32_DM: return None
        out.append((round(x), round(y)))
    return out


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


# ---------------------------------------------------------------------------------------------------------------
# WKB
# ---------------------------------------------------------------------------------------------------------------

def _wkb_header(b, o):
    """(endian, base type 1-7, dims, offset after header) for the geometry at b[o]. ISO (1000/2000/3000 + n) and EWKB
    (Z/M/SRID flag bits) type codes are both understood; the Z and M ordinates are skipped by the readers."""
    if o + 5 > len(b): raise ValueError("truncated WKB header")
    if b[o] not in (0, 1): raise ValueError("bad WKB byte order")
    e = "<" if b[o] == 1 else ">"
    t, = struct.unpack_from(e + "I", b, o + 1)
    o += 5
    hasz = bool(t & 0x80000000) or 1000 <= (t & 0xFFFF) < 2000 or 3000 <= (t & 0xFFFF) < 4000
    hasm = bool(t & 0x40000000) or 2000 <= (t & 0xFFFF) < 4000
    if t & 0x20000000:
        if o + 4 > len(b): raise ValueError("truncated WKB SRID")
        o += 4
    return e, (t & 0xFFFF) % 1000, 2 + hasz + hasm, o


def _count(b, o, e, unit):
    """A uint32 element count at b[o], rejected unless `count * unit` bytes can follow."""
    if o + 4 > len(b): raise ValueError("truncated WKB count")
    n, = struct.unpack_from(e + "I", b, o)
    o += 4
    if n > (len(b) - o) // unit: raise ValueError(f"WKB count {n} exceeds the data")
    return n, o


def _walk(wkb, accept):
    """[(base type, [(x, y), ...])] for every line (2) and outer polygon ring (3) in a geometry. Raises ValueError for
    anything malformed, any base type other than `accept` (a pair of single and multi type codes) and nesting deeper
    than MAX_WKB_DEPTH."""
    single, multi = accept
    out = []
    if not isinstance(wkb, (bytes, bytearray, memoryview)): raise ValueError("geometry is not bytes")
    b = bytes(wkb)

    def read(o, depth):
        if depth > MAX_WKB_DEPTH: raise ValueError("WKB nesting too deep")
        e, t, dims, o = _wkb_header(b, o)
        if t == single == 2:
            n, o = _count(b, o, e, 8 * dims)
            pts = struct.unpack_from(e + f"{dims * n}d", b, o)
            out.append((2, [(pts[dims * j], pts[dims * j + 1]) for j in range(n)]))
            return o + 8 * dims * n
        if t == single == 3:
            nr, o = _count(b, o, e, 4)
            for i in range(nr):
                m, o = _count(b, o, e, 8 * dims)
                pts = struct.unpack_from(e + f"{dims * m}d", b, o)
                o += 8 * dims * m
                if i == 0: out.append((3, [(pts[dims * j], pts[dims * j + 1]) for j in range(m)]))
            return o
        if t == multi:
            n, o = _count(b, o, e, 9)
            for _ in range(n): o = read(o, depth + 1)
            return o
        raise ValueError(f"WKB type {t}")

    try: read(0, 0)
    except (struct.error, IndexError, OverflowError, MemoryError) as ex: raise ValueError(f"malformed WKB: {type(ex).__name__}") from ex
    return out


def polygons(wkb):
    """Outer rings (lon, lat lists) of a WKB Polygon / MultiPolygon (little- or big-endian; ISO or EWKB Z/M/SRID flags
    tolerated, Z/M ordinates dropped). Holes are ignored. ValueError on anything else or on malformed bytes."""
    return [pts for _, pts in _walk(wkb, (3, 6))]


def lines(wkb):
    """Vertex lists (lon, lat) of a WKB LineString / MultiLineString, with the same tolerance and errors as polygons."""
    return [pts for _, pts in _walk(wkb, (2, 5))]


def geom_kind(wkb):
    """"line" for LineString / MultiLineString, "polygon" for Polygon / MultiPolygon, else None (also for None, short
    or malformed input)."""
    try: _, t, _, _ = _wkb_header(bytes(wkb), 0)
    except (ValueError, TypeError): return None
    return "line" if t in (2, 5) else ("polygon" if t in (3, 6) else None)
