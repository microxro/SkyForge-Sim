#!/usr/bin/env python3
# SKYFORGE — Apache-2.0
"""Land cover for a showcase airport: ESA WorldCover 2021 v200 classes on a local metre grid.

Source: ESA WorldCover 10 m 2021 v200 (© ESA WorldCover project, CC BY 4.0; contains modified Copernicus
Sentinel data), read from the public `esa-worldcover` bucket. Output: an 8-bit greyscale PNG, row 0 at the
north edge, covering ±half metres about the airport origin in the same local east/north frame as
`GeoOrigin`; each pixel is a WorldCover class code (10 tree cover, 20 shrubland, 30 grassland, 40 cropland,
50 built-up, 60 bare, 70 snow and ice, 80 permanent water, 90 wetland, 95 mangroves, 100 moss and lichen,
0 no data).

    pip install rasterio pillow numpy
    python3 tools/fetch_landcover.py --lat 36.587 --lon -121.843 --out <pack>/landcover.png
"""
import argparse, math

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.windows import from_bounds
from PIL import Image

BASE = "/vsicurl/https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/ESA_WorldCover_10m_2021_v200_{}_Map.tif"
A, E2 = 6_378_137.0, 0.006_694_379_990_14


def radii(lat):
    s = math.sin(math.radians(lat))
    w = math.sqrt(1 - E2 * s * s)
    return A * (1 - E2) / (w * w * w), A / w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--half", type=float, default=40_000)
    ap.add_argument("--size", type=int, default=4_096)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    n, half = a.size, a.half
    mpp = 2 * half / n
    # Latitude/longitude of every output pixel, with GeoOrigin.coordinate's formulas.
    ys = half - (np.arange(n) + 0.5) * mpp
    xs = -half + (np.arange(n) + 0.5) * mpp
    lat = a.lat + ys / radii(a.lat)[0] * 180 / math.pi                      # per row
    mid = np.radians((lat + a.lat) / 2)
    s = np.sin(mid)
    nrad = A / np.sqrt(1 - E2 * s * s)
    lon = a.lon + xs[None, :] / (nrad * np.cos(mid))[:, None] * 180 / math.pi  # rows x columns
    lat2 = np.repeat(lat[:, None], n, axis=1)

    out = np.zeros((n, n), np.uint8)
    lat0, lat1 = float(lat.min()), float(lat.max())
    lon0, lon1 = float(lon.min()), float(lon.max())
    for tlat in range(int(math.floor(lat0 / 3) * 3), int(math.floor(lat1 / 3) * 3) + 1, 3):
        for tlon in range(int(math.floor(lon0 / 3) * 3), int(math.floor(lon1 / 3) * 3) + 1, 3):
            name = f"{'N' if tlat >= 0 else 'S'}{abs(tlat):02d}{'E' if tlon >= 0 else 'W'}{abs(tlon):03d}"
            w0, w1 = max(lon0, tlon), min(lon1, tlon + 3)
            s0, s1 = max(lat0, tlat), min(lat1, tlat + 3)
            if w1 <= w0 or s1 <= s0:
                continue
            try:
                src = rasterio.open(BASE.format(name))
            except Exception as e:            # open ocean has no tile: permanent water
                print(f"{name}: no tile ({type(e).__name__}); treated as water")
                sel = (lat2 >= tlat) & (lat2 < tlat + 3) & (lon >= tlon) & (lon < tlon + 3)
                out[sel] = 80
                continue
            with src:
                pad = 0.002
                win = from_bounds(max(tlon, w0 - pad), max(tlat, s0 - pad), min(tlon + 3, w1 + pad), min(tlat + 3, s1 + pad), src.transform)
                win = win.round_offsets().round_lengths()
                # Read at about half the output pixel (nearest: these are class codes).
                deg = mpp / 111_320 / 2
                scale = max(1, int(deg / abs(src.transform.a)))
                h, w = max(1, int(win.height / scale)), max(1, int(win.width / scale))
                data = src.read(1, window=win, out_shape=(h, w), resampling=Resampling.nearest)
                wt = src.window_transform(win)
                left, top = wt.c, wt.f
                px, py = wt.a * win.width / w, wt.e * win.height / h
                sel = (lat2 >= tlat) & (lat2 < tlat + 3) & (lon >= tlon) & (lon < tlon + 3)
                ci = np.clip(((lon[sel] - left) / px).astype(int), 0, w - 1)
                ri = np.clip(((lat2[sel] - top) / py).astype(int), 0, h - 1)
                out[sel] = data[ri, ci]
                print(f"{name}: {w} x {h} read, {int(sel.sum())} pixels")
    Image.fromarray(out, "L").save(a.out, optimize=True)
    classes, counts = np.unique(out, return_counts=True)
    print({int(c): round(float(k) / out.size * 100, 1) for c, k in zip(classes, counts)})


if __name__ == "__main__":
    main()
