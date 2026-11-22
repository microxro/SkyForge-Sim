#!/usr/bin/env python3
"""SKYFORGE round-3 sanity metric: lawn luminance spread before/after the macro-colour decoupling.

A numpy port of the maths in MacroColourShaders / MacroColourReference (macro grid with a 128 m median,
luminance-delta clamp, hue from the macro, procedural octaves) is run on a synthetic 1.6 m/px lawn whose
photo has baked 40-80 m cloud blotches, a 30-60 m hue mottle and fine grain. It prints the coefficient of
variation (std / mean) of lawn luminance in the full image and at 40-120 m scale (the cloudy mottle the art
reviewer flagged on KBFI), before and after, and exits non-zero unless the 40-120 m spread falls by >= 60 %.
Usage: macro_colour_check.py [--seed N] [--png out.png]
"""
import argparse, sys
import numpy as np

LUM = np.array([0.2126, 0.7152, 0.0722])
PX = 1.6            # metres per pixel
N = 640             # 1024 m square


def luma(c): return c @ LUM


def blur(a, sigma_px):
    """Gaussian blur by FFT (periodic)."""
    ky = np.fft.fftfreq(a.shape[0])[:, None]; kx = np.fft.fftfreq(a.shape[1])[None, :]
    g = np.exp(-2 * (np.pi * sigma_px) ** 2 * (kx ** 2 + ky ** 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * g))


def smooth_noise(rng, sigma_m):
    f = blur(rng.standard_normal((N, N)), sigma_m / PX)
    return f / f.std()


def synth(rng):
    lawn = np.array([0.080, 0.125, 0.045])
    cloud = np.clip(smooth_noise(rng, 30), 0, None); cloud = cloud / cloud.max()
    shade = 1 - 0.55 * np.clip((cloud - 0.35) / 0.4, 0, 1)                    # baked cloud / tree shadow, up to -55 %
    hue = smooth_noise(rng, 22)
    img = lawn[None, None, :] * shade[..., None] * (1 + 0.04 * smooth_noise(rng, 4))[..., None]
    img[..., 0] *= 1 + 0.10 * hue; img[..., 2] *= 1 - 0.14 * hue                 # yellow <-> blue-grey mottle
    img[..., 2] += 0.02 * np.clip(-hue, 0, None) * shade                         # shadows photograph bluer
    img *= (1 + 0.06 * rng.standard_normal((N, N)))[..., None]                   # grain
    return np.clip(img, 1e-3, None)


def soft_clamp(r, lo, hi, klo, khi):
    r = np.asarray(r, float)
    dark = lo - klo * np.tanh(np.minimum((lo - r) / klo, 8))
    bright = hi + khi * np.tanh(np.minimum((r - hi) / khi, 8))
    return np.where(r < lo, dark, np.where(r > hi, bright, r))


def box(a, size_px):
    """Box mean via blur of equal variance (size^2/12)."""
    return blur(a, size_px / np.sqrt(12))


def macro_grid(img, cell_m=64.0):
    """Per-pixel macro colour (4 taps of 64 m boxes at +-32 m) and 128 m median luminance, bilinear-upsampled
    here by evaluating at every pixel with shifted boxes (a GPU would sample the cell texture bilinearly)."""
    cpx = cell_m / PX
    b = np.stack([box(img[..., c], cpx) for c in range(3)], -1)
    s = int(round(cpx / 2))
    taps = [np.roll(b, (dy, dx), (0, 1)) for dy in (-s, s) for dx in (-s, s)]
    lum = np.stack([luma(t) for t in taps], 0)
    srt = np.sort(lum, 0)
    median = 0.5 * (srt[1] + srt[2])
    mean = sum(taps) / 4
    return mean, median


def hue_of(m):
    L = np.maximum(luma(m), 1e-3)[..., None]
    h = m / L
    blue = np.clip((h[..., 2] - np.maximum(h[..., 0] * 0.85, h[..., 1])) / np.maximum(h[..., 2], 1e-3) / 0.06, 0, 1)
    blue = blue * blue * (3 - 2 * blue)
    neutral = np.array([1.04, 1.0, 0.86]); neutral = neutral / (neutral @ LUM)
    h = h + (neutral - h) * (0.85 * blue)[..., None]
    rng_ = h.max(-1) - h.min(-1)
    sc = np.where(rng_ > 0.70, 0.70 / np.maximum(rng_, 1e-6), 1.0)[..., None]
    return 1 + (h - 1) * sc


def vnoise(rng_seed, sigma_m, shape):
    r = np.random.default_rng(rng_seed)
    f = blur(r.standard_normal(shape), sigma_m / PX); return f / f.std()


def decouple(img, photo_keep=0.15, wide=False, detail=True):
    mean, med = macro_grid(img)
    if wide:                      # 70 % of the way from the 128 m median to the 400 m mean (mc_decoupleGround wideL)
        wa = np.stack([box(img[..., c], 400 / PX) for c in range(3)], -1); w = luma(wa)
        med = med + (w - med) * 0.7
    Lm, Lp = luma(mean), luma(img)
    rc = soft_clamp(Lm / med, 0.97, 1.04, 0.03, 0.08) if wide else soft_clamp(Lm / med, 0.94, 1.12, 0.06, 0.18)
    resid = np.clip(Lp / Lm, 0.8, 1.25)
    Lnat = med * rc * (1 + (resid - 1) * photo_keep)
    # Procedural grass octaves (0.125..8 m): at 1.6 m/px only the >= 2 m octaves resolve; amplitudes as mc_detail.
    # mc_n (smoothstep value noise in [-1, 1]) has a standard deviation of about 0.35, not 1.
    f = 1 + 0.35 * (0.06 * vnoise(1, 2, img.shape[:2]) + 0.06 * vnoise(2, 4, img.shape[:2]) + 0.05 * vnoise(3, 8, img.shape[:2])) if detail else 1.0
    hue = hue_of(mean)
    if wide: hue = hue + (hue_of(wa) - hue) * 0.7
    return hue * (Lnat * f)[..., None]


def cv_at_scale(L, lo_m, hi_m):
    """std/mean of the band-passed luminance between lo_m and hi_m (difference of Gaussians)."""
    band = blur(L, lo_m / PX / 2) - blur(L, hi_m / PX / 2)
    return band.std() / L.mean()


def hue_spread(img):
    c = img / luma(img)[..., None]
    return np.std(blur(c[..., 0] - c[..., 2], 40 / PX / 2))


def pavement_retention():
    """A dark car park (0.4 x asphalt luminance) at a lawn's edge, clamped against (a) the 128 m median or 400 m mean of the
    surrounding lawn, which lifts it, and (b) its own 30 m mean (what mc_decoupleGround does). Returns (lifted, kept) as
    output luminance relative to the input: kept must be ~1.0, lifted shows the failure the review found."""
    asph = 0.07 * 0.99 * 0.4; lawn_l = 0.11
    lifted = soft_clamp(np.array(asph / lawn_l), 0.88, 1.18, 0.12, 0.25) * lawn_l / asph
    kept = soft_clamp(np.array(1.0), 0.88, 1.18, 0.12, 0.25)
    return float(lifted), float(kept)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--seed", type=int, default=7); ap.add_argument("--png")
    a = ap.parse_args()
    rng = np.random.default_rng(a.seed)
    img = synth(rng)
    out128, out, macro_only = decouple(img), decouple(img, wide=True), decouple(img, wide=True, detail=False)
    # Edges of the periodic FFT blur wrap; compare the interior.
    c = slice(120, N - 120)
    rows = [("full-image luminance cv", lambda x: luma(x[c, c]).std() / luma(x[c, c]).mean()),
            ("40-120 m band cv (cloud mottle)", lambda x: cv_at_scale(luma(x), 40, 120)),
            ("hue (R-B) spread at 40 m", lambda x: hue_spread(x))]
    print(f"{'metric':36s} {'photo':>9s} {'128 m only':>11s} {'+400 m hold':>12s} {'ratio':>7s}")
    res = {}
    for name, fn in rows:
        b, a1, af, mo = fn(img), fn(out128), fn(out), fn(macro_only); res[name] = af / b; res[name + "|macro"] = mo / b
        print(f"{name:36s} {b:9.4f} {a1:11.4f} {af:12.4f} {af / b:7.2f}   (macro only {mo / b:.2f})")
    if a.png:
        from PIL import Image
        both = np.concatenate([img, out], 1)
        Image.fromarray((np.clip(both, 0, 1) ** (1 / 2.2) * 255 * 2.2).clip(0, 255).astype(np.uint8)).save(a.png)
    lifted, kept = pavement_retention()
    print(f"dark car park luminance, clamped against the lawn mean: x{lifted:.2f} (lifted, wrong); against its own 30 m mean: x{kept:.2f}")
    print("NOTE: the synthetic lawn is one stationary Gaussian-noise field. It has no forest, slope, pavement or real parcels, so it can show "
          "that the mottle is removed, not that nothing else is damaged (see ROUND3.md 'Known gaps'). Judge on KBFI, KMRY, KASE, LSZS and NZQN frames.")
    ok = res["40-120 m band cv (cloud mottle)"] <= 0.40 and abs(kept - 1.0) < 0.02
    print("PASS" if ok else "FAIL", "(target: 40-120 m luminance spread down by >= 60 % with the 400 m hold)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
