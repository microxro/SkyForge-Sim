// SKYFORGE — Apache-2.0
// Round 3: macro-colour decoupling and cloud-shadow mitigation for photo ground.
//
// The aerial photo is used only as a 64–128 m colour lookup (hue, saturation and a 128 m median luminance).
// Everything finer than that comes from procedural grass, soil and rock driven by vector masks and
// footprint-faded octaves (0.125–8 m). Baked cloud and tree shadows are removed by clamping the photo's
// luminance against the 128 m median (chroma comes from the macro colour, so a shadow cannot tint the
// ground), while real-time cascaded shadows and cloud shadows still apply in the lighting, which this code
// never touches: it outputs albedo only.
//
// Library order (WorldRenderer): `CloudShaders.common + MacroColourShaders.source + WorldShaders.source`; world_fragment
// calls `mc_decoupleGround`, so this source must come BEFORE it. It has no dependency on WorldShaders (all helpers are
// prefixed `mc_`). Runtime flag: `WorldRenderer.macroColourDecoupling` (u.quality.w), default off. CPU mirror:
// `MacroColourReference` (SFRender). Host: `MacroColourPass`. Integration notes: docs/rounds/ROUND3.md.

public enum MacroColourShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ---------------------------------------------------------------------------------------------
    // Small helpers
    // ---------------------------------------------------------------------------------------------
    constant float3 mc_lumW = float3(0.2126, 0.7152, 0.0722);
    constant float3 mc_warm = float3(1.04, 1.0, 0.86);       // warm neutral that blue-cast ground becomes

    static float mc_luma(float3 c) { return dot(c, mc_lumW); }

    // Periodic value noise (period 4096 m), cells must divide 4096: use powers of two.
    static float mc_hash(float2 i, float period) {
        i = fmod(fmod(i, period) + period, period);
        float2 p = fract(i * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return fract((p.x + p.y) * p.x);
    }
    static float mc_vnoise(float2 x, float period) {
        float2 i = floor(x), f = fract(x);
        float2 s = f * f * (3.0 - 2.0 * f);
        float a = mc_hash(i, period), b = mc_hash(i + float2(1, 0), period);
        float c = mc_hash(i + float2(0, 1), period), d = mc_hash(i + float2(1, 1), period);
        return mix(mix(a, b, s.x), mix(c, d, s.x), s.y) * 2.0 - 1.0;
    }
    /// Noise in [-1, 1] with cells `cell` metres across (cell = 2^k, 0.125 … 8).
    static float mc_n(float2 w, float cell) { return mc_vnoise(w / cell, 4096.0 / cell); }
    /// Octave weight: 1 while a pixel is much smaller than the cell, 0 once the cell spans about 1.2 pixels.
    static float mc_fade(float fp, float cell) { return saturate(1.0 - fp / (0.6 * cell)); }

    // ---------------------------------------------------------------------------------------------
    // Macro colour: hue and saturation from the 64–128 m mean
    // ---------------------------------------------------------------------------------------------
    /// Unit-luminance chroma ratio (rgb / luminance) of a macro albedo, with blue-dominant colour (shade and
    /// cloud shadow photograph sky-blue) moved to a warm neutral and the saturation capped, so a macro texel
    /// that sits under a cloud cannot carry its cast into the ground.
    static float3 mc_macroHue(float3 macroAlb) {
        float L = max(mc_luma(macroAlb), 1e-3);
        float3 h = macroAlb / L;
        float blue = smoothstep(0.0, 0.06, (h.b - max(h.r * 0.85, h.g)) / max(h.b, 1e-3));
        float3 neutral = mc_warm / dot(mc_warm, mc_lumW);
        h = mix(h, neutral, 0.85 * blue);
        float range = max(h.r, max(h.g, h.b)) - min(h.r, min(h.g, h.b));
        const float cap = 0.70;                                // linear grass is ~0.5, dry grass ~0.6
        if (range > cap) h = float3(1.0) + (h - 1.0) * (cap / range);
        return h;
    }

    // ---------------------------------------------------------------------------------------------
    // Cloud-shadow clamp: luminance delta against the 128 m median, chroma untouched
    // ---------------------------------------------------------------------------------------------
    /// Soft clamp of the ratio r = luminance / median. Identity inside [lo, hi]; outside, a tanh roll-off
    /// that tends to lo − kLo (dark) or hi + kHi (bright). With the pavement band (0.88, 1.18, 0.12, 0.25) a dark
    /// blotch (cloud and tree shadow, 20–80 m) is pulled to no lower than 0.76 of the median, a bright one to no
    /// higher than 1.43; the lawn bands are tighter. The argument is clamped because
    /// fast-math tanh of a large value is inf/inf = NaN (round 24).
    static float mc_softClamp(float r, float lo, float hi, float kLo, float kHi) {
        if (r < lo) return lo - kLo * tanh(min((lo - r) / kLo, 8.0));
        if (r > hi) return hi + kHi * tanh(min((r - hi) / kHi, 8.0));
        return r;
    }
    /// Albedo with its luminance delta against `medianL` clamped and its chroma (rgb / luminance) unchanged.
    /// Use on ground that keeps the photo's own structure (pavement, roofs).
    static float3 mc_cloudClamp(float3 albedo, float medianL) {
        float L = max(mc_luma(albedo), 1e-4), M = max(medianL, 0.01);
        float rc = mc_softClamp(L / M, 0.88, 1.18, 0.12, 0.25);
        return albedo * (M * rc / L);
    }

    // ---------------------------------------------------------------------------------------------
    // Ground classes from the MACRO colour (not the pixel): a lawn pixel that photographs blue-grey no
    // longer classes as pavement and takes grass detail (round 37), and class weights cannot mottle.
    // ---------------------------------------------------------------------------------------------
    struct MCClasses { float grass, dry, soil, rock, pave; };

    /// `macroAlb` linear albedo of the 64–128 m mean; `forest` 0…1 canopy score (the caller's imgForest);
    /// `steep` 0…1 slope (1 − n.z remapped, 0 flat, 1 cliff); `roadNear` and `burb` the vector masks.
    static MCClasses mc_classify(float3 macroAlb, float forest, float steep, float roadNear, float burb) {
        float hi = max(macroAlb.r, max(macroAlb.g, macroAlb.b)), lo = min(macroAlb.r, min(macroAlb.g, macroAlb.b));
        float chroma = (hi - lo) / max(hi, 1e-3);
        float l = mc_luma(macroAlb);
        MCClasses k;
        k.grass = smoothstep(0.0, 0.03, macroAlb.g - max(macroAlb.r, macroAlb.b) * 0.92) * (1.0 - forest);
        k.dry = smoothstep(0.08, 0.25, (macroAlb.r - macroAlb.b) / max(hi, 1e-3)) * smoothstep(0.02, 0.10, l) * (1.0 - k.grass);
        // Rock: steep and low chroma (cliffs, scree), never in the suburbs.
        k.rock = smoothstep(0.45, 0.75, steep) * (1.0 - smoothstep(0.12, 0.30, chroma)) * (1.0 - burb);
        // Pavement: grey macro colour on flat ground, or any road-mask hit (the mask is vector truth).
        k.pave = max((1.0 - smoothstep(0.10, 0.22, chroma)) * (1.0 - k.grass) * (1.0 - smoothstep(0.30, 0.55, steep)), 0.0);
        k.pave = max(k.pave * (1.0 - k.rock), roadNear * 0.6);
        k.soil = max(0.0, 1.0 - k.grass - k.dry - k.rock - k.pave) * (1.0 - forest);
        float sum = max(1e-3, k.grass + k.dry + k.soil + k.rock + k.pave);
        float scale = (1.0 - forest) / sum;
        k.grass *= scale; k.dry *= scale; k.soil *= scale; k.rock *= scale; k.pave *= scale;
        return k;
    }

    // ---------------------------------------------------------------------------------------------
    // Procedural detail 0.125 … 8 m
    // ---------------------------------------------------------------------------------------------
    /// Multiplicative luminance detail (mean ≈ 1) and a warm/cool tint for natural classes at world point `w`
    /// (metres, period 4096), pixel footprint `fp` (metres). `tilt` receives a normal tilt (x, y slope).
    static float mc_detail(MCClasses k, float2 w, float fp, float roadNear, float burb,
                           thread float2& tilt, thread float3& tint) {
        float f = 1.0;
        tint = float3(1.0);
        tilt = float2(0.0);
        float e;
        if (k.grass > 0.01) {
            float blades = mc_n(w + 5.3, 0.125) * mc_fade(fp, 0.125);
            float clumps = mc_n(w - 9.1, 1.0) * mc_fade(fp, 1.0);
            float tufts  = mc_n(w + 41.0, 2.0) * mc_fade(fp, 2.0);
            float patch4 = mc_n(w - 63.0, 4.0) * mc_fade(fp, 4.0);
            float patch8 = mc_n(w + 23.0, 8.0) * mc_fade(fp, 8.0);
            float g = 1.0 + 0.08 * blades + 0.08 * clumps + 0.06 * saturate(tufts) - 0.10 * saturate(-tufts)
                          + 0.06 * patch4 + 0.05 * patch8;
            f *= mix(1.0, g, k.grass);
            tint *= mix(float3(1.0), mix(float3(0.93, 0.99, 0.90), float3(1.06, 1.02, 0.88), saturate(patch8 * 0.5 + 0.5)),
                        0.5 * k.grass * mc_fade(fp, 8.0));
            e = 0.25;
            tilt += float2(mc_n(w + float2(e, 0) - 9.1, 1.0) - mc_n(w - float2(e, 0) - 9.1, 1.0),
                           mc_n(w + float2(0, e) - 9.1, 1.0) - mc_n(w - float2(0, e) - 9.1, 1.0)) * (0.30 * mc_fade(fp, 1.0) * k.grass);
        }
        if (k.dry > 0.01) {
            // Wind-laid streaks: noise stretched along a slowly turning direction.
            float a = 0.6 + 1.2 * mc_n(w + 61.0, 8.0);
            float2 d = float2(cos(a), sin(a));
            float2 sw = float2(dot(w, d) / 3.0, dot(w, float2(-d.y, d.x)) * 2.0);
            float streak = mc_n(sw + 13.0, 1.0) * mc_fade(fp, 1.0);
            float tuft = mc_n(w - 3.7, 0.25) * mc_fade(fp, 0.25);
            float bare = mc_n(w + 44.0, 4.0) * mc_fade(fp, 4.0);
            float g = (1.0 + 0.12 * streak + 0.14 * tuft) * (1.0 - 0.10 * saturate(bare));
            f *= mix(1.0, g, k.dry);
        }
        if (k.soil > 0.01) {
            float pebbles = mc_n(w + 2.9, 0.125) * mc_fade(fp, 0.125);
            float clods = mc_n(w - 17.0, 0.5) * mc_fade(fp, 0.5);
            float blotch = mc_n(w + 8.0, 4.0) * mc_fade(fp, 4.0);
            float g = (1.0 + 0.14 * pebbles) * (1.0 + 0.12 * clods) * (1.0 + 0.14 * blotch);
            f *= mix(1.0, g, k.soil);
            tint *= mix(float3(1.0), float3(0.94, 0.97, 1.02), 0.5 * saturate(-blotch) * k.soil);
        }
        if (k.rock > 0.01) {
            // Strata: ridged noise stretched across the slope, broken by 4 m blocks, with lichen speckle.
            float ridge = 1.0 - abs(mc_n(float2(w.x * 0.25, w.y * 2.0) + 7.0, 1.0));
            float blocks = mc_n(w - 31.0, 4.0) * mc_fade(fp, 4.0);
            float speck = mc_n(w + 97.0, 0.125) * mc_fade(fp, 0.125);
            float lichen = smoothstep(0.55, 0.85, mc_n(w + 13.0, 0.5)) * mc_fade(fp, 0.5);
            float g = (0.90 + 0.14 * ridge * mc_fade(fp, 1.0)) * (1.0 + 0.10 * blocks) * (1.0 + 0.10 * speck);
            f *= mix(1.0, g, k.rock);
            tint *= mix(float3(1.0), float3(0.92, 1.0, 0.85), 0.35 * lichen * k.rock);
            e = 0.25;
            tilt += float2(mc_n(w + float2(e, 0) + 31.0, 1.0) - mc_n(w - float2(e, 0) + 31.0, 1.0),
                           mc_n(w + float2(0, e) + 31.0, 1.0) - mc_n(w - float2(0, e) + 31.0, 1.0)) * (0.35 * mc_fade(fp, 1.0) * k.rock);
        }
        // Road verge (vector mask): a 4–8 m strip of dried, gravelly ground beside every road.
        float verge = roadNear * (1.0 - k.pave);
        if (verge > 0.01) {
            float gravel = mc_n(w + 71.0, 0.125) * mc_fade(fp, 0.125);
            f *= 1.0 + verge * (0.10 * gravel - 0.06);
            tint *= mix(float3(1.0), float3(1.08, 1.02, 0.85), 0.5 * verge);
        }
        // Suburban lawns (vector mask): mowing bands 8 m wide, ±3 %, one direction per 128 m block, faded
        // before they moire.
        if (burb > 0.01 && k.grass > 0.01) {
            float2 blk = floor(w / 128.0) * 128.0;
            float ang = 3.14159 * (0.5 + 0.5 * mc_n(blk + 71.0, 8.0));
            float st = sin(dot(w, float2(cos(ang), sin(ang))) * (6.28318 / 8.0));
            f *= 1.0 + 0.03 * st * burb * k.grass * saturate(1.0 - fp / 4.0);
        }
        return f;
    }

    // ---------------------------------------------------------------------------------------------
    // Main entry: replaces the near-ground tone-map stack in world_fragment
    // ---------------------------------------------------------------------------------------------
    /// `albedo`    photoAlbedo of the pixel's own photo colour (kept only for pavement and a small residual);
    /// `macroAlb`  photoAlbedo of the 64–128 m macro colour (macro_colour_build rgb);
    /// `medianL`   luminance of photoAlbedo(macro colour at the 128 m median luminance), must be > 0;
    /// `localL`    luminance of the ~30 m photo mean (the old ltMean), the clamp median for pavement and roofs, so a car
    ///             park or a dark roof keeps its own tone; <= 0 falls back to `medianL`;
    /// `wideAlb`   photoAlbedo of the ~400 m photo mean (the old lm4 tap), float3(0) to disable. On flat, non-forest
    ///             ground its luminance AND hue (70 %) lead the 64–128 m values: a 128 m window cannot remove 60–120 m
    ///             mottle (the median itself carries ~40 % of it, tools/macro_colour_check.py), as round 62 held 85–92 %.
    ///             Forest and steep ground never take the wide pull (their dark, shaded tone is real);
    /// `forest`    canopy score (those pixels are left entirely to the caller's old path); `steep` slope 0…1;
    ///             `roadNear`, `burb` vector masks;
    /// `w`, `fp`   region metres modulo 4096 and pixel footprint (m);
    /// `amount`    0…1 gate (distance fade × not water × not runway × not clearing);
    /// `photoKeep` 0…0.2 weight of the pixel's own luminance relative to the macro (0 = strictly macro).
    /// Returns the new albedo and the weight to blend it in with (`amount` × not forest): the caller does
    /// `albedo = mix(albedo, result, weight)` so a partly forested pixel keeps the old canopy path's albedo, and
    /// `groundTilt = mix(groundTilt, tilt, weight)`. `albedo` here is the PHOTO albedo from before the old stack.
    static float3 mc_decoupleGround(float3 albedo, float3 macroAlb, float medianL, float localL, float3 wideAlb, float forest,
                                    float steep, float roadNear, float burb, float2 w, float fp, float amount, float photoKeep,
                                    thread float2& tilt, thread float& weight) {
        tilt = float2(0.0);
        weight = amount * (1.0 - saturate(forest));               // canopy stays on the existing path
        if (weight <= 0.0 || medianL <= 0.0) { weight = 0.0; return albedo; }
        float M = max(medianL, 0.01);
        float wideL = mc_luma(wideAlb);
        // The 400 m pull only where the old code also pulled (flat, not forest); elsewhere the 128 m median alone.
        float wideGate = wideL > 0.0 ? (1.0 - saturate(forest)) * (1.0 - smoothstep(0.25, 0.55, steep)) : 0.0;
        float Mw = mix(M, max(wideL, 0.01), 0.7 * wideGate);
        float Lm = max(mc_luma(macroAlb), 1e-3);
        float Lp = max(mc_luma(albedo), 1e-4);
        MCClasses k = mc_classify(macroAlb, forest, steep, roadNear, burb);

        // Natural ground: hue and saturation from the macro, luminance from the clamped macro (the clamp pulls
        // a texel that sits under a cloud toward the median), a bounded share of the pixel's own luminance, then
        // procedural detail. No photo high frequency survives except that share.
        float3 hue = mc_macroHue(macroAlb);
        if (wideGate > 0.0) hue = mix(hue, mc_macroHue(wideAlb), 0.7 * wideGate);
        // Tighter than pavement (lawns are flat tone), and tighter again once the median leans on the 400 m mean.
        float rc = mc_softClamp(Lm / Mw, mix(0.94, 0.97, wideGate), mix(1.12, 1.04, wideGate), mix(0.06, 0.03, wideGate),
                                mix(0.18, 0.08, wideGate));
        float resid = clamp(Lp / Lm, 0.8, 1.25);
        float Lnat = Mw * rc * mix(1.0, resid, photoKeep);
        float2 dt; float3 tint;
        float f = mc_detail(k, w, fp, roadNear, burb, dt, tint);
        float3 natural = hue * (Lnat * f) * tint;

        // Pavement and roofs keep the photo's structure; the luminance-delta clamp is against the 30 m mean (never
        // the 400 m mean, which would lift car parks, aprons and dark roofs toward the surrounding lawn).
        float3 paved = mc_cloudClamp(albedo, localL > 0.0 ? localL : M);

        float pw = saturate(k.pave);
        tilt = dt * (1.0 - pw);
        return mix(natural, paved, pw);
    }

    // ---------------------------------------------------------------------------------------------
    // Compute: the macro-colour texture (one texel per ~64 m over the near imagery square)
    // ---------------------------------------------------------------------------------------------
    struct MCBuildParams {
        float2 centre;        // near imagery centre (region metres)
        float halfExtent;     // near imagery half extent (m)
        float cellMetres;     // output texel size (2 * halfExtent / size, close to 64 m)
        float texelMetres;    // near imagery metres per texel (2 * halfExtent / width)
        uint size;            // output is size × size, row 0 north (as the imagery)
        uint2 pad;
    };  // MSL: float2 (8) + 3 floats (12) + uint (4) = 24 B, then uint2 pad at 24 → 32 B total; Swift mirror: MacroColourBuildParams

    /// out.rgb = linear photo colour averaged over 128 m (four 64 m mip taps at ±32 m); out.a = the MEDIAN of
    /// those four taps' luminance (mean of the middle two), the 128 m median. The photo's sRGB texture gives
    /// linear values. The caller applies photoAlbedo(out.rgb) and photoAlbedo(out.rgb * (out.a / luma(out.rgb))).
    kernel void macro_colour_build(texture2d<float> img [[texture(0)]],
                                   texture2d<float, access::write> out [[texture(1)]],
                                   constant MCBuildParams& p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.size || gid.y >= p.size) return;
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge, coord::normalized);
        float x0 = p.centre.x - p.halfExtent, y1 = p.centre.y + p.halfExtent;
        float2 c = float2(x0 + (float(gid.x) + 0.5) * p.cellMetres, y1 - (float(gid.y) + 0.5) * p.cellMetres);
        float lod = max(0.0, log2(p.cellMetres / max(p.texelMetres, 1e-3)));
        float k = 1.0 / (2.0 * p.halfExtent);
        float3 col[4];
        float lum[4];
        for (int i = 0; i < 4; i++) {
            float2 o = float2((i & 1) ? 32.0 : -32.0, (i & 2) ? 32.0 : -32.0) * (p.cellMetres / 64.0);
            float2 q = c + o;
            float2 uv = (q - (p.centre - p.halfExtent)) * k; uv.y = 1.0 - uv.y;
            col[i] = img.sample(s, uv, level(lod)).rgb;
            lum[i] = mc_luma(col[i]);
        }
        // Median of four: sort the luminances, average the middle pair.
        float a = min(lum[0], lum[1]), b = max(lum[0], lum[1]), cc = min(lum[2], lum[3]), d = max(lum[2], lum[3]);
        float lo2 = max(a, cc), hi2 = min(b, d);
        float median = 0.5 * (lo2 + hi2);
        float3 mean = 0.25 * (col[0] + col[1] + col[2] + col[3]);
        out.write(float4(mean, median), gid);
    }
    """
}
