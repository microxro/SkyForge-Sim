#!/usr/bin/env python3
# SKYFORGE — Apache-2.0
"""Bundle LINZ aerial imagery into a showcase tile pack as Web Mercator tiles.

Source: Toitū Te Whenua Land Information New Zealand aerial imagery, CC BY 4.0, read from the public
`nz-imagery` bucket (cloud-optimised GeoTIFFs in NZTM2000). The tool warps the surveys onto slippy-map
tiles and stores them in the pack under `LINZAerialProvider`'s keys, so the app loads them offline like
any other tile. Pixels no survey covers (open water, gaps) are filled from the pack's own Sentinel-2
tiles, so every written tile is complete.

    pip install rasterio pyproj pillow
    python3 tools/fetch_linz_imagery.py --pack <pack-dir> --lat -45.018282 --lon 168.746643 \
        --layer 15:7800:0:0 --layer 17:3600:-873:-218 --layer 18:2300:-1500:-375 \
        --dataset otago/queenstown_2021_0.1m --dataset otago/otago_2019-2021_0.3m

A layer is zoom:half-extent-metres:east-offset:north-offset about (lat, lon). Datasets are listed best
first; a later one only fills what the earlier ones left empty.
"""
import argparse, hashlib, io, json, math, os, re, subprocess, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import rasterio
import rasterio.warp
import rasterio.windows
from rasterio.enums import Resampling
from rasterio.transform import from_origin
from rasterio.vrt import WarpedVRT
from rasterio.windows import from_bounds
from pyproj import Transformer
from PIL import Image, ImageFilter

BUCKET = "https://nz-imagery.s3.ap-southeast-2.amazonaws.com"
KEY = "skyforge-pack://linz-aerial/{z}/{x}/{y}.jpg"
ATTRIBUTION = "Imagery: Toitū Te Whenua Land Information New Zealand aerial imagery, CC BY 4.0"
S2 = "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg"
ORIGIN = 20037508.342789244


def http(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def list_tiffs(dataset):
    keys, token = [], None
    while True:
        url = f"{BUCKET}/?list-type=2&prefix={dataset}/rgb/2193/"
        if token:
            url += "&continuation-token=" + urllib.request.quote(token, safe="")
        body = http(url).decode()
        keys += [k for k in re.findall(r"<Key>([^<]+)</Key>", body) if k.endswith(".tiff")]
        m = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", body)
        if not m:
            return keys
        token = m.group(1)


def sheet_bounds(keys):
    """NZTM bounds of each tile from its name (sheet, scale, row, column); one header read per sheet."""
    out, origins = {}, {}
    for k in keys:
        m = re.search(r"/([A-Z]{2}\d{2})_(\d+)_(\d{2})(\d{2})\.tiff$", k)
        if not m:
            continue
        sheet, scale, row, col = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
        w, h = scale * 0.48, scale * 0.72          # a 1:1000 tile is 480 m by 720 m
        if (sheet, scale) not in origins:
            with rasterio.open(f"/vsicurl/{BUCKET}/{k}") as src:
                b = src.bounds
            origins[(sheet, scale)] = (b.left - (col - 1) * w, b.top + (row - 1) * h)
        ox, oy = origins[(sheet, scale)]
        left, top = ox + (col - 1) * w, oy - (row - 1) * h
        out[k] = (left, top - h, left + w, top)
    return out


def tile_range(lat, lon, half, de, dn, z):
    mlat = 111_132.0
    mlon = 111_320.0 * math.cos(math.radians(lat))
    n = 1 << z

    def xy(la, lo):
        return (lo + 180) / 360 * n, (1 - math.asinh(math.tan(math.radians(la))) / math.pi) / 2 * n

    x0, y0 = xy(lat + (dn + half) / mlat, lon + (de - half) / mlon)
    x1, y1 = xy(lat + (dn - half) / mlat, lon + (de + half) / mlon)
    return int(x0), int(y0), int(x1), int(y1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", required=True)
    ap.add_argument("--lat", type=float, required=True)
    ap.add_argument("--lon", type=float, required=True)
    ap.add_argument("--layer", action="append", required=True)
    ap.add_argument("--dataset", action="append", required=True)
    ap.add_argument("--quality", type=int, default=78)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    to_nztm = Transformer.from_crs(3857, 2193, always_xy=True)
    index = []
    for ds in a.dataset:
        keys = list_tiffs(ds)
        b = sheet_bounds(keys)
        print(f"{ds}: {len(b)} tiles", flush=True)
        index.append((ds, b))

    manifest_path = os.path.join(a.pack, "manifest.json")
    manifest = json.load(open(manifest_path))
    written = 0
    for spec in a.layer:
        z, half, de, dn = spec.split(":")
        z, half, de, dn = int(z), float(half), float(de), float(dn)
        tx0, ty0, tx1, ty1 = tile_range(a.lat, a.lon, half, de, dn, z)
        size = 2 * ORIGIN / (1 << z)
        left, top = -ORIGIN + tx0 * size, ORIGIN - ty0 * size
        W, H = (tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256
        res = size / 256
        right, bottom = left + W * res, top - H * res
        dst = from_origin(left, top, res, res)
        # The mosaic's footprint in NZTM (corners and edge midpoints, padded).
        xs, ys = [], []
        for fx in (0, 0.5, 1):
            for fy in (0, 0.5, 1):
                x, y = to_nztm.transform(left + fx * (right - left), bottom + fy * (top - bottom))
                xs.append(x); ys.append(y)
        box = (min(xs) - 50, min(ys) - 50, max(xs) + 50, max(ys) + 50)
        rgb = np.zeros((H, W, 3), np.uint8)
        have = np.zeros((H, W), bool)
        print(f"z{z}: {tx1 - tx0 + 1} x {ty1 - ty0 + 1} tiles, {W} x {H} px at {res * math.cos(math.radians(a.lat)):.2f} m", flush=True)
        for ds, bounds in index:
            if have.all():
                break
            sources = [k for k, b in bounds.items() if b[0] < box[2] and b[2] > box[0] and b[1] < box[3] and b[3] > box[1]]
            print(f"  {ds}: {len(sources)} source tiles", flush=True)
            if a.dry_run:
                continue

            def read(k):
                with rasterio.open(f"/vsicurl/{BUCKET}/{k}") as src:
                    with WarpedVRT(src, crs="EPSG:3857", transform=dst, width=W, height=H, resampling=Resampling.bilinear, add_alpha=src.count == 3) as vrt:
                        wb = rasterio.warp.transform_bounds(src.crs, "EPSG:3857", *src.bounds)
                        x0, x1 = max(wb[0], left), min(wb[2], right)
                        y0, y1 = max(wb[1], bottom), min(wb[3], top)
                        if x1 <= x0 or y1 <= y0:
                            return None
                        c0, c1 = max(0, int((x0 - left) / res)), min(W, int(math.ceil((x1 - left) / res)))
                        r0, r1 = max(0, int((top - y1) / res)), min(H, int(math.ceil((top - y0) / res)))
                        if c1 <= c0 or r1 <= r0:
                            return None
                        w = rasterio.windows.Window(c0, r0, c1 - c0, r1 - r0)
                        d = vrt.read(window=w)
                        return (r0, r1, c0, c1, d)

            with ThreadPoolExecutor(6) as ex:
                for i, got in enumerate(ex.map(read, sources)):
                    if got is None:
                        continue
                    r0, r1, c0, c1, d = got
                    ok = d[-1] > 0
                    if d.shape[0] >= 4:
                        ok &= ~((d[0] == 0) & (d[1] == 0) & (d[2] == 0))
                    ok &= ~have[r0:r1, c0:c1]
                    block = rgb[r0:r1, c0:c1]
                    block[ok] = np.moveaxis(d[:3], 0, -1)[ok]
                    have[r0:r1, c0:c1] |= ok
                    if i % 20 == 0:
                        print(f"    {i + 1}/{len(sources)} covered {have.mean() * 100:.1f} %", flush=True)
        if a.dry_run:
            continue
        print(f"  covered {have.mean() * 100:.1f} %", flush=True)
        if not have.all():
            # Fill from Sentinel-2 cloudless 2016 (z14 at most), upsampled.
            sz = min(z, 14)
            k = z - sz
            sx0, sy0, sx1, sy1 = tx0 >> k, ty0 >> k, tx1 >> k, ty1 >> k
            mos = np.zeros(((sy1 - sy0 + 1) * 256, (sx1 - sx0 + 1) * 256, 3), np.uint8)
            for sy in range(sy0, sy1 + 1):
                for sx in range(sx0, sx1 + 1):
                    url = S2.format(z=sz, x=sx, y=sy)
                    h = manifest["files"].get(url)
                    body = open(os.path.join(a.pack, h), "rb").read() if h else http(url)
                    mos[(sy - sy0) * 256:(sy - sy0 + 1) * 256, (sx - sx0) * 256:(sx - sx0 + 1) * 256] = np.asarray(Image.open(io.BytesIO(body)).convert("RGB"))
            scale = 1 << k
            ox, oy = (tx0 - (sx0 << k)) * 256, (ty0 - (sy0 << k)) * 256
            big = Image.fromarray(mos).resize((mos.shape[1] * scale, mos.shape[0] * scale), Image.BICUBIC)
            fill = np.asarray(big.crop((ox, oy, ox + W, oy + H)))
            # Feather the survey's edge into the fill over a few pixels.
            cov = Image.fromarray((have * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6))
            wgt = (np.asarray(cov).astype(np.float32) / 255)[..., None]
            wgt = np.where(have[..., None], np.clip(wgt * 2 - 1, 0, 1), 0)
            rgb = (rgb * wgt + fill * (1 - wgt)).astype(np.uint8)
        for ty in range(ty0, ty1 + 1):
            for tx in range(tx0, tx1 + 1):
                t = rgb[(ty - ty0) * 256:(ty - ty0 + 1) * 256, (tx - tx0) * 256:(tx - tx0 + 1) * 256]
                buf = io.BytesIO()
                Image.fromarray(t).save(buf, "JPEG", quality=a.quality, subsampling=2, progressive=False, optimize=False)
                body = buf.getvalue()
                h = hashlib.sha256(body).hexdigest()
                with open(os.path.join(a.pack, h), "wb") as f:
                    f.write(body)
                manifest["files"][KEY.format(z=z, x=tx, y=ty)] = h
                written += 1
    if a.dry_run:
        return
    for line in (ATTRIBUTION,):
        if line not in manifest["attribution"]:
            manifest["attribution"].insert(0, line)
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {written} tiles")


if __name__ == "__main__":
    main()
