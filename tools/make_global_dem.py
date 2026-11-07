#!/usr/bin/env python3
"""Build the bundled offline global DEM baseline from AWS Terrain Tiles (Terrarium, zoom 4).
Usage: make_global_dem.py <dir with t_4_X_Y.png> <output dir>
Output: global_dem.sfdem: equirectangular 4096 x 2048 Int16 metres (lon -180..180, lat 90..-90, pixel centres),
stored as zlib-compressed 256x256 tiles.  Layout (little-endian):
  magic "SFDEM1\\0\\0" | u32 width | u32 height | u32 tile | u32 tilesX | u32 tilesY | (u64 offset, u32 length) per tile | tile data
Latitudes beyond Web Mercator's ±85.05° are clamped to the nearest available row (documented limitation).
Also writes global_dem.json with the SHA-256 and attribution."""
import hashlib, json, os, struct, sys, zlib
import numpy as np
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
Z, N = 4, 16
merc = np.zeros((N * 256, N * 256), dtype=np.float32)
for x in range(N):
    for y in range(N):
        im = np.asarray(Image.open(os.path.join(src, f"t_4_{x}_{y}.png")).convert("RGB"), dtype=np.float32)
        merc[y * 256:(y + 1) * 256, x * 256:(x + 1) * 256] = im[..., 0] * 256 + im[..., 1] + im[..., 2] / 256 - 32768
W, H, T = 4096, 2048, 256
lon = (np.arange(W) + 0.5) / W * 360 - 180
lat = 90 - (np.arange(H) + 0.5) / H * 180
latc = np.clip(lat, -85.0511, 85.0511)
fy = (1 - np.arcsinh(np.tan(np.radians(latc))) / np.pi) / 2 * merc.shape[0] - 0.5
fx = (lon + 180) / 360 * merc.shape[1] - 0.5
X, Y = np.meshgrid(fx, fy)
x0 = np.floor(X).astype(int); y0 = np.floor(Y).astype(int); tx = X - x0; ty = Y - y0
def at(yy, xx): return merc[np.clip(yy, 0, merc.shape[0] - 1), np.mod(xx, merc.shape[1])]
dem = (at(y0, x0) * (1 - tx) * (1 - ty) + at(y0, x0 + 1) * tx * (1 - ty) + at(y0 + 1, x0) * (1 - tx) * ty + at(y0 + 1, x0 + 1) * tx * ty)
# Despike: replace isolated artefacts (> 2 km from the 3x3 median) with the median.
pad = np.pad(dem, 1, mode="edge")
stack = np.stack([pad[1 + dy:1 + dy + H, 1 + dx:1 + dx + W] for dy in (-1, 0, 1) for dx in (-1, 0, 1)])
med = np.median(stack, axis=0)
spikes = np.abs(dem - med) > 2000
print("despiked pixels:", int(spikes.sum()))
dem = np.where(spikes, med, dem)
dem = np.clip(np.round(dem), -11000, 9000).astype("<i2")
tilesX, tilesY = W // T, H // T
blobs = [zlib.compress(dem[ty * T:(ty + 1) * T, tx * T:(tx + 1) * T].tobytes(), 9) for ty in range(tilesY) for tx in range(tilesX)]
header = b"SFDEM1\0\0" + struct.pack("<5I", W, H, T, tilesX, tilesY)
table_size = len(blobs) * 12
offset = len(header) + table_size
table = b""
for b in blobs:
    table += struct.pack("<QI", offset, len(b)); offset += len(b)
out = header + table + b"".join(blobs)
path = os.path.join(dst, "global_dem.sfdem")
open(path, "wb").write(out)
meta = {"file": "global_dem.sfdem", "sha256": hashlib.sha256(out).hexdigest(), "bytes": len(out), "width": W, "height": H,
        "tile": T, "source": "AWS Terrain Tiles (Terrarium) zoom 4, https://registry.opendata.aws/terrain-tiles/",
        "attribution": "Elevation: AWS Terrain Tiles (Mapzen/Tilezen joerd); sources include SRTM, GMTED2010, ETOPO1, NED, and others per tilezen/joerd docs/attribution.md",
        "min": int(dem.min()), "max": int(dem.max())}
json.dump(meta, open(os.path.join(dst, "global_dem.json"), "w"), indent=2, sort_keys=True)
print(json.dumps(meta, indent=1))
# Reference samples for tests
for name, la, lo in [("Everest", 27.9881, 86.9250), ("Dead Sea", 31.5, 35.5), ("Pacific", 0.0, -150.0), ("Denver", 39.74, -104.99)]:
    r = int((90 - la) / 180 * H); c = int((lo + 180) / 360 * W)
    print(name, int(dem[r, c]))
