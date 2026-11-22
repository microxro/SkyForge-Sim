#!/usr/bin/env python3
"""Offline tests for overture_common / fetch_buildings / fetch_landuse / fetch_roads. No network, no pytest:
    python3 tools/test_overture_tools.py
"""
import math, os, re, struct, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import overture_common as oc
import fetch_buildings as fb
import fetch_landuse as fl
import fetch_roads as fr


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


if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn(); n += 1; print("ok", name)
    print(f"{n} tests passed")
