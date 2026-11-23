#!/usr/bin/env python3
"""Offline tests for overture_common / fetch_buildings / fetch_landuse / fetch_roads. No network, no pytest:
    python3 tools/test_overture_tools.py
"""
import math, os, random, re, struct, sys, tempfile, time
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import overture_common as oc
import fetch_buildings as fb
import fetch_landuse as fl
import fetch_roads as fr
import fetch_airport_surfaces as fa


def wkb_poly(rings, e="<"):
    b = bytearray((b"\x01" if e == "<" else b"\x00") + struct.pack(e + "I", 3))
    b += struct.pack(e + "I", len(rings))
    for r in rings:
        b += struct.pack(e + "I", len(r))
        for x, y in r: b += struct.pack(e + "dd", x, y)
    return bytes(b)


def wkb_multi(polys, e="<"):
    b = bytearray((b"\x01" if e == "<" else b"\x00") + struct.pack(e + "II", 6, len(polys)))
    for p in polys: b += wkb_poly(p, e)
    return bytes(b)


SQ = [(0, 0), (1, 0), (1, 1), (0, 1), (0, 0)]


def test_polygons():
    for e in "<>":
        assert oc.polygons(wkb_poly([SQ], e)) == [SQ]
    hole = [(.2, .2), (.4, .2), (.4, .4), (.2, .2)]
    assert oc.polygons(wkb_poly([SQ, hole])) == [SQ]                   # hole dropped, outer kept
    far = [(x + 5, y + 5) for x, y in SQ]
    assert oc.polygons(wkb_multi([[SQ, hole], [far]])) == [SQ, far]
    assert oc.polygons(wkb_multi([[SQ], [far]], ">")) == [SQ, far]
    # ISO Z polygon (type 1003): z ordinate skipped
    z = b"\x01" + struct.pack("<III", 1003, 1, 4) + b"".join(struct.pack("<ddd", x, y, 9.0) for x, y in SQ[:3] + [SQ[0]])
    assert oc.polygons(z) == [[SQ[0], SQ[1], SQ[2], SQ[0]]]
    try: oc.polygons(b"\x01" + struct.pack("<I", 1) + b"\0" * 16); assert False
    except ValueError: pass


def test_aspect_ratio():
    assert abs(fb.aspect_ratio([(0, 0), (10, 0), (10, 10), (0, 10)]) - 1) < 1e-9
    assert abs(fb.aspect_ratio([(0, 0), (20, 0), (20, 10), (0, 10)]) - 2) < 1e-9
    c, s = math.cos(0.7), math.sin(0.7)                                # rotation invariant
    rot = [(x * c - y * s, x * s + y * c) for x, y in [(0, 0), (30, 0), (30, 10), (0, 10)]]
    assert abs(fb.aspect_ratio(rot) - 3) < 1e-6
    assert fb.aspect_ratio([(0, 0), (1, 1)]) == 1.0
    assert fb.aspect_ratio([(0, 0), (5, 0), (10, 0)]) == 1.0           # collinear


def test_jitter_height_roof():
    assert fb.jitter(123, -456) == fb.jitter(123, -456)
    vals = [fb.jitter(x, y) for x in range(-50, 50) for y in range(-5, 5)]
    assert all(0.0 <= v <= 1.0 for v in vals) and len(set(vals)) > 900
    kinds = fb.KINDS + ["weird"]
    for k in kinds:
        for area in (5, 25, 60, 150, 300, 500, 900, 1500, 2000, 3000, 5000, 20000):
            for u in (0.0, 0.5, 1.0):
                h = fb.infer_height(k, area, 0, u)
                assert h == fb.infer_height(k, area, 0, u) and 2.9 <= h <= 20.0, (k, area, u, h)
    assert fb.infer_height("house", 100, 2, 0.3) == 2 * 3.2 + 1
    assert 5 <= fb.infer_height("house", 100, 0, 0) <= fb.infer_height("house", 100, 0, 1) <= 8.0
    for u in (0.0, 0.34, 0.67, 0.999, 1.0):                            # 3-5 storeys
        assert 3.2 * 3 + 1 - 1e-9 <= fb.infer_height("apartments", 500, 0, u) <= 3.2 * 5 + 1 + 1e-9
    assert fb.infer_height("shed", 10, 0, 1.0) == 3.4
    F, G, H = (fb.ROOFS.index(n) for n in ("flat", "gabled", "hipped"))
    assert fb.infer_roof("house", 700, 2.0, 0, 6) == F
    assert fb.infer_roof("commercial", 100, 2.0, 0, 6) == F
    assert fb.infer_roof("commercial", 80, 2.0, 0, 6) == G
    assert fb.infer_roof("house", 150, 1.35, 0, 6) == G
    assert fb.infer_roof("house", 150, 1.34, 0, 6) == H
    assert fb.infer_roof("house", 10, 3.0, 0, 6) == F
    for k in kinds:
        for area in (5, 50, 100, 649, 651, 9000):
            assert 0 < fb.infer_roof(k, area, 1.5, 0, 5) < len(fb.ROOFS)


def parse_sfb1(data):
    """Independent reader following the fetch_buildings.py docstring layout."""
    assert data[:4] == b"SFB1"
    lat, lon, count = struct.unpack_from("<ddI", data, 4)
    o, recs = 24, []
    for _ in range(count):
        x, y, hd, mh, kind, roof, lv, fl, rr, rg, rb, wr, wg, wb, n = struct.unpack_from("<iiHHBBBBBBBBBBH", data, o)
        o += 24
        pts = [(x, y)]
        for _ in range(n - 1):
            dx, dy = struct.unpack_from("<hh", data, o); o += 4
            pts.append((pts[-1][0] + dx, pts[-1][1] + dy))
        recs.append(dict(h=hd, mh=mh, kind=kind, roof=roof, levels=lv, flags=fl, rc=(rr, rg, rb), wc=(wr, wg, wb), pts=pts))
    assert o == len(data)
    return lat, lon, count, recs


def test_encode_sfb1():
    lat, lon = 47.53, -122.30
    box = oc.region_box(lat, lon, 1)
    mlat, mlon = box[4], box[5]
    assert abs(mlat - 111132) < 1 and abs(mlon - 111320 * math.cos(math.radians(lat))) < 1

    def sq(x0, y0, w, h):                                              # metres east/north of origin -> lon/lat ring
        m = [(x0, y0), (x0 + w, y0), (x0 + w, y0 + h), (x0, y0 + h), (x0, y0)]
        return [(lon + x / mlon, lat + y / mlat) for x, y in m]
    rows = [
        {"geometry": wkb_poly([sq(0, 0, 12, 8)]), "class": "house", "height": 7.5, "roof_shape": "hipped",
         "num_floors": 2, "min_height": 1.0, "roof_color": "#ff8000", "facade_color": "#000000", "has_parts": True},
        {"geometry": wkb_poly([sq(-40, 20, 30, 10)]), "class": "Warehouse"},                 # all inferred
        {"geometry": wkb_poly([sq(0, 0, 4000, 5)]), "class": "yes"},                         # 4 km edge -> dx overflow i16 (dm), dropped
        {"geometry": b"garbage", "class": "house"},                                          # bad WKB, skipped
        {"geometry": wkb_poly([[(lon, lat), (lon, lat), (lon, lat)]]), "class": "house"},    # degenerate, dropped
        {"geometry": wkb_multi([[sq(100, 100, 10, 10)], [sq(130, 100, 10, 10)]]), "subtype": "residential"},
    ]
    stats = Counter()
    data, count = fb.encode(rows, lat, lon, mlat, mlon, True, stats)
    la, lo, c2, recs = parse_sfb1(bytes(data))
    assert (la, lo) == (lat, lon) and c2 == count == len(recs) == 4, count
    r = recs[0]
    assert r["pts"][0] == (0, 0) and len(r["pts"]) == 4                    # closing vertex dropped
    assert r["pts"][2] == (120, 80)
    assert r["h"] == 75 and r["mh"] == 10 and r["kind"] == 1 and r["roof"] == fb.ROOFS.index("hipped") and r["levels"] == 2
    assert r["flags"] == 0b0011 and r["rc"] == (255, 128, 1) and r["wc"] == (1, 1, 1)
    w = recs[1]
    assert w["flags"] == 0b1100 and w["kind"] == fb.KINDS.index("warehouse") and w["roof"] == fb.ROOFS.index("flat")
    assert 70 <= w["h"] <= 120 and w["rc"] == (0, 0, 0)
    assert recs[3]["kind"] == fb.KINDS.index("residential") and recs[3]["flags"] & 13 == 12
    assert stats["height_inferred"] == 3 and stats["roof_inferred"] == 3 and stats["roof_flat"] + stats["roof_gabled"] + stats["roof_hipped"] == 4
    # deterministic bytes
    assert bytes(fb.encode(rows, lat, lon, mlat, mlon, True, Counter())[0]) == bytes(data)
    # --no-infer: raw attributes, no inference bits
    raw, n = fb.encode(rows, lat, lon, mlat, mlon, False, Counter())
    rr = parse_sfb1(bytes(raw))[3]
    assert n == 4 and rr[1]["h"] == 0 and rr[1]["roof"] == 0 and rr[1]["flags"] == 0 and rr[0]["flags"] == 3
    # flags and kind/roof tables agree with the Swift reader if the repo is checked out
    swift = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "SkyforgeKit", "Sources", "SFQuickFlight", "BuildingPack.swift")
    if os.path.exists(swift):
        src = open(swift).read()
        for name, py in (("kinds", fb.KINDS), ("roofs", fb.ROOFS)):
            m = re.search(r"static let %s = \[(.*?)\]" % name, src, re.S)
            assert m and re.findall(r'"([^"]*)"', m.group(1)) == py, name


def test_encode_sfl1():
    lat, lon = 47.53, -122.30
    box = oc.region_box(lat, lon, 1); mlat, mlon = box[4], box[5]
    def sq(x0, y0, s): return [(lon + x / mlon, lat + y / mlat) for x, y in [(x0, y0), (x0 + s, y0), (x0 + s, y0 + s), (x0, y0 + s), (x0, y0)]]
    rows = [{"geometry": wkb_poly([sq(0, 0, 10)]), "class": "parking", "surface": "asphalt"},
            {"geometry": wkb_poly([sq(0, 0, 100)]), "class": "residential"},
            {"geometry": wkb_poly([sq(0, 0, 50)]), "subtype": "park"},
            {"geometry": wkb_poly([sq(0, 0, 30)]), "class": "zzz"}]
    data, polys = fl.encode(rows, lat, lon, mlat, mlon)
    assert data[:4] == b"SFL1"
    la, lo, n = struct.unpack_from("<ddI", data, 4); o = 24
    assert (la, lo, n) == (lat, lon, 4)
    seen = []
    for _ in range(n):
        cat, flags, m, x, y = struct.unpack_from("<BBHii", data, o); o += 12
        pts = [(x, y)]
        for _ in range(m - 1):
            dx, dy = struct.unpack_from("<hh", data, o); o += 4; pts.append((pts[-1][0] + dx, pts[-1][1] + dy))
        seen.append((cat, flags, m, pts))
    assert o == len(data)
    assert [s[0] for s in seen] == [1, 4, 0, 11]                         # largest first
    assert seen[0][3][2] == (1000, 1000) and seen[3][1] == 1 and seen[0][1] == 0 and all(s[2] == 4 for s in seen)
    assert len(fl.CATEGORIES) == 12 and fl.CATEGORIES[11] == "transport"
    swift = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "SkyforgeKit", "Sources", "SFQuickFlight", "LandUsePack.swift")
    if os.path.exists(swift):
        m = re.search(r"case other, (.*)", open(swift).read())
        assert ["other"] + [x.strip() for x in m.group(1).split(",")] == fl.CATEGORIES
    assert max(fl.CLASS_MAP.values()) < len(fl.CATEGORIES) and max(fl.SUBTYPE_MAP.values()) < len(fl.CATEGORIES)


def test_landuse_long_edge():
    lat, lon = 47.53, -122.30
    box = oc.region_box(lat, lon, 1); mlat, mlon = box[4], box[5]
    big = [(lon + x / mlon, lat + y / mlat) for x, y in [(0, 0), (8000, 0), (8000, 6000), (0, 6000), (0, 0)]]
    data, polys = fl.encode([{"geometry": wkb_poly([big]), "class": "park"}], lat, lon, mlat, mlon)
    assert len(polys) == 1
    o = 24; cat, fg, m, x, y = struct.unpack_from("<BBHii", data, o); o += 12
    pts = [(x, y)]
    for _ in range(m - 1):
        dx, dy = struct.unpack_from("<hh", data, o); o += 4; pts.append((pts[-1][0] + dx, pts[-1][1] + dy))
    assert o == len(data) and m > 4 and pts[-1] != pts[0]
    assert max(p[0] for p in pts) == 80000 and max(p[1] for p in pts) == 60000
    assert fl.ring_area(pts) == 80000 * 60000


def test_flags_and_roads():
    assert fr.flagged([{"values": ["is_bridge"]}], "is_bridge")
    assert fr.flagged([{"values": ["is_bridge"], "between": [0.0, 0.9]}], "is_bridge")
    assert not fr.flagged([{"values": ["is_bridge"], "between": [0.0, 0.2]}], "is_bridge")
    assert not fr.flagged(None, "is_bridge")
    wkb = b"\x01" + struct.pack("<II", 2, 2) + struct.pack("<4d", 1, 2, 3, 4)
    assert fr.linestring(wkb) == [(1, 2), (3, 4)]
    wkb = b"\x00" + struct.pack(">II", 2, 2) + struct.pack(">4d", 1, 2, 3, 4)
    assert fr.linestring(wkb) == [(1, 2), (3, 4)]


def test_sources_filter():
    osm, esri, none = {"sources": [{"dataset": "OpenStreetMap"}]}, {"sources": [{"dataset": "Esri Community Maps"}, {"dataset": "OpenStreetMap"}]}, {}
    default = oc.parse_sources("OpenStreetMap")
    assert default == {"OpenStreetMap"}
    assert oc.source_allowed(osm, default) and not oc.source_allowed(esri, default) and not oc.source_allowed(none, default)
    assert oc.source_allowed(esri, oc.parse_sources("OpenStreetMap, Esri Community Maps"))   # primary source only, spaces trimmed
    assert oc.parse_sources(" ANY ") is None and all(oc.source_allowed(r, None) for r in (osm, esri, none, {"sources": []}))
    assert oc.parse_sources("") == {"OpenStreetMap"} and oc.parse_sources(",") == {"OpenStreetMap"}
    assert oc.source_dataset({"sources": [{"dataset": None}]}) == ""
    # every tool defaults to OSM only
    here = os.path.dirname(os.path.abspath(__file__))
    for f in ("fetch_buildings.py", "fetch_landuse.py", "fetch_roads.py"):
        assert re.search(r'"--sources",\s*default="OpenStreetMap"', open(os.path.join(here, f)).read()), f


def test_region_and_index():
    b = oc.region_box(0.0, 10.0, 1)
    assert b[0] < 10 < b[1] and b[2] < 0 < b[3]
    idx = [("a", 1, [(0, 1, 0, 1), (5, 6, 5, 6), None]), ("b", 1, [(5, 6, 5, 6)])]
    assert list(oc.row_groups_in_box(idx, (0.5, 2, 0.5, 2))) == [("a", 1, [0, 2])]


class FakeRaw:
    def __init__(self, data): self.data = data
    def read(self, n=-1, decode_content=False): return self.data if n < 0 else self.data[:n]


class FakeResp:
    def __init__(self, status=200, text="", content=b"", headers=None):
        if text and not content: content = text.encode()
        self.status_code, self.text, self.content, self.headers = status, text, content, headers or {}
        self.raw = FakeRaw(content)
    def close(self): pass


def ranged(headers, body):
    """A 206 answer whose Content-Range matches the request's Range header."""
    a, b = headers["Range"].split("=")[1].split("-")
    return FakeResp(206, content=body, headers={"Content-Range": f"bytes {a}-{b}/100"})


def with_session(fake, fn):
    """Run fn with oc.SESSION.get replaced by `fake` and time.sleep disabled."""
    real_get, real_sleep = oc.SESSION.get, time.sleep
    oc.SESSION.get = fake; time.sleep = lambda s: None
    try: return fn()
    finally: oc.SESSION.get = real_get; time.sleep = real_sleep


def listing(keys, token=None):
    body = "".join(f"<Contents><Key>{k}</Key><Size>{n}</Size></Contents>" for k, n in keys)
    return "<ListBucketResult>" + body + (f"<NextContinuationToken>{token}</NextContinuationToken>" if token else "") + "</ListBucketResult>"


def raises(exc, fn):
    try: fn()
    except exc: return True
    return False


def test_list_files_hardening():
    # a 500 must raise, not return an empty listing
    assert raises(oc.FetchError, lambda: with_session(lambda *a, **k: FakeResp(500, "oops"), lambda: oc.list_files("r")))
    assert raises(oc.FetchError, lambda: with_session(lambda *a, **k: FakeResp(403, "<Error><Code>AccessDenied</Code></Error>"), lambda: oc.list_files("r")))
    # 200 with an S3 error document, or an unrelated body
    assert raises(oc.FetchError, lambda: with_session(lambda *a, **k: FakeResp(200, "<Error><Code>SlowDown</Code></Error>"), lambda: oc.list_files("r")))
    assert raises(oc.FetchError, lambda: with_session(lambda *a, **k: FakeResp(200, "<html>captive portal</html>"), lambda: oc.list_files("r")))
    # an empty listing (wrong release) raises
    assert raises(oc.FetchError, lambda: with_session(lambda *a, **k: FakeResp(200, listing([])), lambda: oc.list_files("r")))
    # network errors raise FetchError
    def boom(*a, **k): raise oc.requests.ConnectionError("down")
    assert raises(oc.FetchError, lambda: with_session(boom, lambda: oc.list_files("r")))
    # pagination: two pages are joined, only .parquet kept
    pages = [listing([("a.parquet", 1), ("skip.txt", 2)], token="T1"), listing([("b.parquet", 3)])]
    calls = []
    def paged(url, **k):
        calls.append(url); return FakeResp(200, pages[len(calls) - 1])
    assert with_session(paged, lambda: oc.list_files("r")) == [("a.parquet", 1), ("b.parquet", 3)]
    assert "continuation-token=T1" in calls[1] and "continuation-token" not in calls[0]
    # a repeated token cannot loop forever
    assert raises(oc.FetchError, lambda: with_session(lambda *a, **k: FakeResp(200, listing([("a.parquet", 1)], token="SAME")), lambda: oc.list_files("r")))


def test_rangefile_hardening():
    f = oc.RangeFile("http://x/o", 100, block=16)
    calls = []
    def ok(url, headers=None, **k):
        calls.append(headers["Range"]); return ranged(headers, b"x" * 16)
    assert with_session(ok, lambda: f.read(10)) == b"x" * 10
    # 200 = the server ignored Range: fail at once
    calls.clear()
    def full(url, headers=None, **k): calls.append(1); return FakeResp(200, content=b"y" * 100)
    assert raises(IOError, lambda: with_session(full, lambda: oc.RangeFile("http://x/o", 100, 16).read(10))) and len(calls) == 1
    # 404 is not retried
    calls.clear()
    def nf(url, headers=None, **k): calls.append(1); return FakeResp(404)
    assert raises(IOError, lambda: with_session(nf, lambda: oc.RangeFile("http://x/o", 100, 16).read(10))) and len(calls) == 1
    # 503 and short bodies are retried (5 tries) then fail
    calls.clear()
    def bad(url, headers=None, **k): calls.append(1); return ranged(headers, b"z" * 3)
    assert raises(IOError, lambda: with_session(bad, lambda: oc.RangeFile("http://x/o", 100, 16).read(10))) and len(calls) == 5
    calls.clear()
    def flaky(url, headers=None, **k):
        calls.append(1); return FakeResp(503) if len(calls) < 3 else ranged(headers, b"k" * 16)
    assert with_session(flaky, lambda: oc.RangeFile("http://x/o", 100, 16).read(4)) == b"k" * 4 and len(calls) == 3


def test_rangefile_content_range_and_bounds():
    # a 206 whose Content-Range is for another span is refused, not trusted
    def wrong(url, headers=None, **k): return FakeResp(206, content=b"x" * 16, headers={"Content-Range": "bytes 16-31/100"})
    assert raises(IOError, lambda: with_session(wrong, lambda: oc.RangeFile("http://x/o", 100, 16).read(10)))
    # a body longer than requested is not accepted as the span
    def long(url, headers=None, **k): return ranged(headers, b"x" * 40)
    assert raises(IOError, lambda: with_session(long, lambda: oc.RangeFile("http://x/o", 100, 16).read(10)))
    # an absurd span is refused before any request
    assert raises(ValueError, lambda: oc.RangeFile("http://x/o", 1 << 40, 1 << 20)._get(0, 1 << 33))


def test_write_output_and_cache():
    d = tempfile.mkdtemp()
    path = os.path.join(d, "out.bin")
    oc.write_output(path, b"abc", 3)
    assert open(path, "rb").read() == b"abc" and oct(os.stat(path).st_mode & 0o777) == "0o644"
    assert raises(SystemExit, lambda: oc.write_output(path, b"empty", 0))        # refuses to replace a good file
    assert open(path, "rb").read() == b"abc"
    oc.write_output(path, b"empty", 0, allow_empty=True)
    assert open(path, "rb").read() == b"empty"
    new = os.path.join(d, "sub", "new.bin")
    oc.write_output(new, b"e", 0)                                                  # no existing file: warns, writes
    assert open(new, "rb").read() == b"e"
    assert not [n for n in os.listdir(d) if n.endswith(".tmp")]
    # corrupt, truncated and non-object caches load as {}
    c = os.path.join(d, "index.json")
    assert oc.load_index_cache(c) == {}
    for bad in ('{"a": {"size"', "", "[1,2]", "null"):
        open(c, "w").write(bad); assert oc.load_index_cache(c) == {}, bad
    oc.save_index_cache(c, {"k": {"size": 5, "groups": [[0, 1, 0, 1], None]}})
    assert oc.load_index_cache(c)["k"]["size"] == 5
    assert oc._valid_entry({"size": 5, "groups": [[0, 1, 0, 1], None]}, 5)
    assert not oc._valid_entry({"size": 6, "groups": []}, 5) and not oc._valid_entry({"size": 5, "groups": [[0, 1, 0]]}, 5)
    assert not oc._valid_entry({"size": 5, "groups": [[0, 1, 0, "x"]]}, 5) and not oc._valid_entry("x", 5)


def test_region_box_guards():
    for args in ((90, 0, 1), (89.9, 0, 1), (0, 181, 1), (0, 0, 0), (0, 0, -1), (0, 0, 500), (float("nan"), 0, 1), (0, float("inf"), 1), ("x", 0, 1),
                 (0, 179.99, 5), (0, -179.99, 5)):
        assert raises(ValueError, lambda: oc.region_box(*args)), args
    assert oc.region_box(84, 10, 1)[5] > 0
    assert oc.region_box(36.6, -121.8, 3)[0] < -121.8


def test_helpers():
    assert oc.fnum("3.5") == 3.5 and oc.fnum(float("nan")) is None and oc.fnum(float("inf"), 0) == 0 and oc.fnum(None, 7) == 7 and oc.fnum("x") is None
    box = (0, 1, 0, 1)
    assert oc.row_bbox_hit({"bbox": {"xmin": .2, "xmax": .4, "ymin": .2, "ymax": .4}}, box) is True
    assert oc.row_bbox_hit({"bbox": {"xmin": 2, "xmax": 3, "ymin": 0, "ymax": 1}}, box) is False
    for bad in ({}, {"bbox": None}, {"bbox": {"xmin": None, "xmax": 1, "ymin": 0, "ymax": 1}}, {"bbox": {"xmin": float("nan"), "xmax": 1, "ymin": 0, "ymax": 1}}):
        assert oc.row_bbox_hit(bad, box) is None, bad
    assert oc.source_dataset({"sources": [None]}) == "" and oc.source_dataset({"sources": ["x"]}) == ""
    assert oc.project_ring([(0.0, 0.0), (0.001, 0.001)], 0, 0, 111132, 111320) == [(0, 0), (1113, 1111)]
    assert oc.project_ring([(float("nan"), 0)], 0, 0, 1, 1) is None and oc.project_ring([(float("inf"), 0)], 0, 0, 1, 1) is None
    assert oc.project_ring([(1e9, 0)], 0, 0, 111132, 111320) is None                # a bogus 1e9-degree ordinate does not fit an i32 of decimetres
    # width tags: empty, junk, units
    w = lambda v: fa.width_of({"source_tags": [("width", v)]})
    assert w("") == 0.0 and w("   ") == 0.0 and w("wide") == 0.0 and w("nan") == 0.0 and w("-5") == 0.0
    assert w("30") == 30.0 and w("30 m") == 30.0 and w("18,5") == 18.5 and abs(w("98 ft") - 29.8704) < 1e-9 and abs(w("98'") - 29.8704) < 1e-9
    assert w("9999") == 150.0 and fa.width_of({"source_tags": {"width": "12"}}) == 12.0 and fa.width_of({}) == 0.0
    assert fa.is_unpaved({"surface": "Grass"}) and not fa.is_unpaved({"surface": "asphalt"}) and fa.is_unpaved({"source_tags": [("surface", "gravel")]})


def test_wkb_dialects():
    z = lambda t, e="<": (b"\x01" if e == "<" else b"\x00") + struct.pack(e + "I", t)
    # EWKB Z (0x80000003) reads 3 ordinates per point, ISO Z (1003) the same, ISO M (2003) too, ISO ZM (3003) four
    for t, d in ((0x80000003, 3), (1003, 3), (2003, 3), (3003, 4), (0xA0000003, 3)):
        b = z(t) + (struct.pack("<I", 4) if t & 0x20000000 else b"") + struct.pack("<II", 1, 4) + b"".join(struct.pack("<" + "d" * d, x, y, *([7.0] * (d - 2))) for x, y in SQ[:3] + [SQ[0]])
        assert oc.polygons(b) == [[SQ[0], SQ[1], SQ[2], SQ[0]]], t
    # lines, incl. big-endian MultiLineString and Z
    ln = lambda pts, e="<": (b"\x01" if e == "<" else b"\x00") + struct.pack(e + "II", 2, len(pts)) + b"".join(struct.pack(e + "dd", *p) for p in pts)
    assert oc.lines(ln([(1, 2), (3, 4)])) == [[(1, 2), (3, 4)]]
    assert oc.lines(b"\x00" + struct.pack(">II", 5, 2) + ln([(1, 2), (3, 4)], ">") + ln([(5, 6), (7, 8)], ">")) == [[(1, 2), (3, 4)], [(5, 6), (7, 8)]]
    assert oc.geom_kind(ln([(0, 0), (1, 1)])) == "line" and oc.geom_kind(wkb_poly([SQ])) == "polygon" and oc.geom_kind(wkb_multi([[SQ]])) == "polygon"
    assert oc.geom_kind(b"") is None and oc.geom_kind(None) is None and oc.geom_kind(b"\x07abc") is None and oc.geom_kind(b"\x01" + struct.pack("<I", 1) + b"\0" * 16) is None
    assert raises(ValueError, lambda: oc.polygons(ln([(0, 0), (1, 1)]))) and raises(ValueError, lambda: oc.lines(wkb_poly([SQ])))
    # hostile counts fail fast with ValueError, no huge allocation
    assert raises(ValueError, lambda: oc.polygons(b"\x01" + struct.pack("<III", 3, 0xFFFFFFFF, 4)))
    assert raises(ValueError, lambda: oc.polygons(b"\x01" + struct.pack("<IIII", 3, 1, 0xFFFFFFFF, 0)))
    assert raises(ValueError, lambda: oc.polygons(b"\x01" + struct.pack("<II", 6, 0xFFFFFFFF)))
    # deeply nested multi-geometry: bounded, ValueError not RecursionError
    nest = wkb_poly([SQ])
    for _ in range(5000): nest = b"\x01" + struct.pack("<II", 6, 1) + nest
    assert raises(ValueError, lambda: oc.polygons(nest))
    assert raises(ValueError, lambda: oc.polygons("not bytes")) and raises(ValueError, lambda: oc.polygons(None))
    # fetch_roads.linestring wraps lines()
    assert raises(ValueError, lambda: fr.linestring(wkb_poly([SQ]))) and raises(ValueError, lambda: fr.linestring(b"\x01\x02"))


def test_wkb_mutation_fuzz():
    """Seeded mutation fuzz: whatever the bytes, the parsers answer with a result or ValueError, nothing else, and fast."""
    rng = random.Random(0x5F0C)
    seeds = [wkb_poly([SQ]), wkb_poly([SQ, [(.2, .2), (.4, .2), (.4, .4), (.2, .2)]]), wkb_multi([[SQ], [SQ]]), wkb_multi([[SQ]], ">"),
             b"\x01" + struct.pack("<II", 2, 3) + struct.pack("<6d", 0, 0, 1, 1, 2, 0),
             b"\x01" + struct.pack("<II", 1003, 1) + struct.pack("<I", 4) + b"".join(struct.pack("<ddd", x, y, 1.0) for x, y in SQ[:3] + [SQ[0]]),
             b"\x00" + struct.pack(">II", 5, 1) + b"\x00" + struct.pack(">II", 2, 2) + struct.pack(">4d", 0, 0, 1, 1)]
    t0, n = time.time(), 0
    for _ in range(4000):
        b = bytearray(rng.choice(seeds))
        for _ in range(rng.randint(1, 4)):
            m = rng.random()
            if m < 0.5 and b: b[rng.randrange(len(b))] = rng.randrange(256)
            elif m < 0.7 and b: del b[rng.randrange(len(b)):]                  # truncate
            elif m < 0.85: b += bytes(rng.randrange(256) for _ in range(rng.randint(1, 12)))
            elif b and len(b) >= 4:                                              # set a 32-bit word to a hostile value
                o = rng.randrange(len(b) - 3); b[o:o + 4] = struct.pack("<I", rng.choice((0, 1, 0xFFFFFFFF, 0x7FFFFFFF, 1 << 24)))
        for fn in (oc.polygons, oc.lines):
            try:
                out = fn(bytes(b))
                assert isinstance(out, list) and all(isinstance(p, tuple) and len(p) == 2 for ring in out for p in ring)
            except ValueError: pass
        assert oc.geom_kind(bytes(b)) in (None, "line", "polygon")
        n += 1
    assert time.time() - t0 < 30, "fuzz loop too slow"


def test_encoders_survive_bad_rows():
    lat, lon = 47.53, -122.30
    box = oc.region_box(lat, lon, 1); mlat, mlon = box[4], box[5]
    good = [(lon + x / mlon, lat + y / mlat) for x, y in [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]]
    nan_ring = [(float("nan"), lat), (lon, lat), (lon, lat + 1e-4), (float("nan"), lat)]
    far_ring = [(lon + 90, lat), (lon + 90.001, lat), (lon + 90, lat + .001), (lon + 90, lat)]
    rows = [{"geometry": wkb_poly([good]), "class": "house", "height": float("nan"), "num_floors": "two", "min_height": float("inf")},
            {"geometry": wkb_poly([nan_ring]), "class": "house"}, {"geometry": wkb_poly([far_ring]), "class": "house"},
            {"geometry": None}, {}, {"geometry": b""}, {"geometry": b"\xff" * 40}, {"geometry": wkb_poly([good]), "class": 7, "roof_shape": 3}]
    st = Counter()
    data, count = fb.encode(rows, lat, lon, mlat, mlon, True, st)
    assert count == 3 and st["bad_geometry"] == 4 and st["bad_ring"] == 1, (count, dict(st))      # NaN ring rejected; the far ring is valid
    st2 = Counter()
    data, polys = fl.encode(rows, lat, lon, mlat, mlon, st2)
    assert len(polys) == 3 and st2["bad_geometry"] == 4 and st2["bad_ring"] == 1, dict(st2)
    # fa.parts: unusable geometry is None, a point is [] (nothing to draw)
    assert fa.parts({"geometry": b"\xff" * 30, "class": "runway"}) is None or fa.parts({"geometry": b"\xff" * 30, "class": "runway"}) == []
    assert fa.parts({"geometry": wkb_poly([SQ]), "class": "apron"})[0][:3] == ("apron", "polygon", False)
    assert fa.parts({"geometry": b"\x01" + struct.pack("<II", 2, 2) + struct.pack("<4d", 0, 0, 1, 1), "class": "runway", "surface": "grass"})[0][:3] == ("runway", "line", True)
    # the airport tool's old parser silently mis-read EWKB Z as 2D and aborted on ISO Z; the shared one reads both
    assert hasattr(fa, "polygons") and fa.polygons is oc.polygons


def test_cli_validation():
    import subprocess
    here = os.path.dirname(os.path.abspath(__file__))
    for tool, extra in (("fetch_airport_surfaces.py", []), ("fetch_buildings.py", []), ("fetch_landuse.py", []), ("fetch_roads.py", [])):
        r = subprocess.run([sys.executable, os.path.join(here, tool), "--lat", "36.6", "--lon", "-121.8", "--half-km", "0", "--out", "/nonexistent/x"] + extra,
                           capture_output=True, text=True, timeout=30)
        assert r.returncode == 2 and "half-km" in r.stderr, (tool, r.returncode, r.stderr[-200:])
    r = subprocess.run([sys.executable, os.path.join(here, "fetch_airport_surfaces.py"), "--lat", "36.6", "--lon", "-121.8", "--out", "/nonexistent/x", "--png-size", "99999"],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 2 and "png-size" in r.stderr
    r = subprocess.run([sys.executable, os.path.join(here, "fetch_buildings.py"), "--lat", "0", "--lon", "179.99", "--out", "/nonexistent/x"], capture_output=True, text=True, timeout=30)
    assert r.returncode == 2 and "antimeridian" in r.stderr


if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn(); n += 1; print("ok", name)
    print(f"{n} tests passed")
