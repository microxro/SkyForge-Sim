#!/usr/bin/env python3
# SKYFORGE — Apache-2.0
"""Adds Terrarium z12 elevation tiles to a showcase tile pack for the region loader's mid height mosaic
(`RealWorldRegion.midHeights`, 12 km half extent around the airport origin).

The pack's z14 elevation tiles cover the near square (3.2 km half extent, 900 m toward the approach),
so their bounding box locates the airfield to within a z14 tile; the z12 tiles covering that point
±(12 km + margin) are fetched from the public, keyless Terrarium bucket (AWS open data, already credited
in every pack) and stored content-addressed like the rest of the pack.

Usage: tools/fetch_mid_heights.py Packages/SkyforgeKit/Sources/SFQuickFlight/Resources/Showcase/KMRY [...]
"""
import hashlib
import json
import math
import os
import re
import sys
import urllib.request

BASE = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium"
HALF_KM = 15.5   # 12 km mid half extent + offset of the near centre + z14 quantisation


def tile_to_lonlat(x, y, z):
    n = 2 ** z
    lon = x / n * 360 - 180
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    return lon, lat


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y


def main(packs):
    for pack in packs:
        mpath = os.path.join(pack, "manifest.json")
        m = json.load(open(mpath))
        z14 = []
        for u in m["files"]:
            g = re.match(rf"{BASE}/14/(\d+)/(\d+)\.png$", u)
            if g:
                z14.append((int(g.group(1)), int(g.group(2))))
        if not z14:
            print(f"{pack}: no z14 elevation tiles, skipped")
            continue
        xs = [t[0] for t in z14]; ys = [t[1] for t in z14]
        lon0, lat0 = tile_to_lonlat(min(xs), min(ys), 14)
        lon1, lat1 = tile_to_lonlat(max(xs) + 1, max(ys) + 1, 14)
        lon, lat = (lon0 + lon1) / 2, (lat0 + lat1) / 2
        dlat = HALF_KM / 111.32
        dlon = HALF_KM / (111.32 * math.cos(math.radians(lat)))
        x0, y0 = lonlat_to_tile(lon - dlon, lat + dlat, 12)
        x1, y1 = lonlat_to_tile(lon + dlon, lat - dlat, 12)
        added = 0
        for ty in range(y0, y1 + 1):
            for tx in range(x0, x1 + 1):
                url = f"{BASE}/12/{tx}/{ty}.png"
                if url in m["files"]:
                    continue
                with urllib.request.urlopen(url, timeout=60) as r:
                    body = r.read()
                h = hashlib.sha256(body).hexdigest()
                f = os.path.join(pack, h)
                if not os.path.exists(f):
                    with open(f, "wb") as out:
                        out.write(body)
                m["files"][url] = h
                added += 1
        # Keep the manifest's existing style: TilePack.write (Swift) escapes "/" and puts " : " after keys.
        raw = open(mpath).read()
        if "\\/" in raw:
            out = json.dumps(m, indent=2, sort_keys=True, ensure_ascii=False, separators=(",", " : ")).replace("/", "\\/")
        else:
            out = json.dumps(m, indent=2, sort_keys=True, ensure_ascii=False)
        with open(mpath, "w") as f:
            f.write(out + ("\n" if raw.endswith("\n") else ""))
        print(f"{pack}: centre {lat:.4f},{lon:.4f}; z12 x {x0}-{x1} y {y0}-{y1}; {added} tiles added")


if __name__ == "__main__":
    main(sys.argv[1:])
