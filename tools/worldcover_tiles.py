#!/usr/bin/env python3
# SKYFORGE — Apache-2.0
"""Worldwide ESA WorldCover tiles: list the 3°×3° tiles a point needs, and write each as a class-code PNG.

Source: ESA WorldCover 10 m 2021 v200 (© ESA WorldCover project, CC BY 4.0; contains modified Copernicus
Sentinel data), public bucket `esa-worldcover`. Tiles are named by their south-west corner (N36W123).
Ocean-only tiles are not published (the bucket returns 404); they are reported as "absent", not as errors.

Output per tile: 8-bit greyscale PNG, row 0 at the north edge, `--size`² pixels over the whole 3°×3° tile,
each pixel a WorldCover class code (10 tree, 20 shrub, 30 grass, 40 crop, 50 built-up, 60 bare, 70 snow,
80 water, 90 wetland, 95 mangrove, 100 moss, 0 no data). Nearest-neighbour resampling keeps class codes exact.

    pip install rasterio pillow numpy
    python3 tools/worldcover_tiles.py list --lat 36.587 --lon -121.843 --radius-km 150
    python3 tools/worldcover_tiles.py fetch --lat 36.587 --lon -121.843 --radius-km 150 --out-dir <dir>
"""
import argparse
import math
import os
import sys

BUCKET = "https://esa-worldcover.s3.eu-central-1.amazonaws.com"
OBJECT = "v200/2021/map/ESA_WorldCover_10m_2021_v200_{name}_Map.tif"
SPAN = 3
SOUTH_RANGE = range(-60, 82)  # published 60°S to 84°N, on 3° steps: -60 ... 81
WEST_RANGE = range(-180, 180)


def tile_name(south, west):
    ns = "S" if south < 0 else "N"
    ew = "W" if west < 0 else "E"
    return f"{ns}{abs(south):02d}{ew}{abs(west):03d}"


def tile_for(lat, lon):
    lon = (lon + 180) % 360 - 180
    return (math.floor(lat / SPAN) * SPAN, math.floor(lon / SPAN) * SPAN)


def covering(lat, lon, radius_m):
    """Same bounding-box rule as WorldCoverTileKey.covering in SFWorldGen (keep the two in step)."""
    dlat = radius_m / 111_320.0
    cos_lat = math.cos(math.radians(lat))
    dlon = min(180.0, radius_m / (111_320.0 * cos_lat)) if cos_lat > 1e-6 else 180.0
    south_min = math.floor(max(-90.0, lat - dlat) / SPAN) * SPAN
    north_max = math.floor(min(89.999, lat + dlat) / SPAN) * SPAN
    west_min = math.floor((lon - dlon) / SPAN) * SPAN
    east_max = math.floor((lon + dlon) / SPAN) * SPAN
    out = set()
    s = south_min
    while s <= north_max:
        w = west_min
        while w <= east_max:
            wrapped = (w + 180) % 360 - 180
            if s in SOUTH_RANGE and wrapped in WEST_RANGE:
                out.add((s, wrapped))
            w += SPAN
        s += SPAN
    return sorted(out)


def fetch_tile(south, west, size, out_path):
    import numpy as np
    import rasterio
    from PIL import Image
    from rasterio.enums import Resampling

    url = f"/vsicurl/{BUCKET}/{OBJECT.format(name=tile_name(south, west))}"
    with rasterio.open(url) as src:
        # The tile's window in the source grid, read at `size` pixels with nearest-neighbour resampling.
        window = rasterio.windows.from_bounds(west, south, west + SPAN, south + SPAN, src.transform)
        data = src.read(1, window=window, out_shape=(size, size), resampling=Resampling.nearest)
    Image.fromarray(np.asarray(data, dtype=np.uint8), mode="L").save(out_path, optimize=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["list", "fetch"])
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--radius-km", type=float, default=150.0)
    ap.add_argument("--size", type=int, default=2048, help="pixels per tile side")
    ap.add_argument("--out-dir", help="directory for fetched PNGs (fetch only)")
    args = ap.parse_args()

    tiles = covering(args.lat, args.lon, args.radius_km * 1000.0)
    if args.command == "list":
        for s, w in tiles:
            print(f"{tile_name(s, w)}\t{BUCKET}/{OBJECT.format(name=tile_name(s, w))}")
        print(f"{len(tiles)} tiles; centre tile {tile_name(*tile_for(args.lat, args.lon))}", file=sys.stderr)
        return

    os.makedirs(args.out_dir, exist_ok=True)
    for s, w in tiles:
        name = tile_name(s, w)
        out = os.path.join(args.out_dir, f"worldcover_{name}.png")
        if os.path.exists(out):
            continue
        try:
            fetch_tile(s, w, args.size, out)
            print(f"wrote {out}", file=sys.stderr)
        except Exception as exc:  # 404 for ocean-only tiles; log and move on
            print(f"absent {name}: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
