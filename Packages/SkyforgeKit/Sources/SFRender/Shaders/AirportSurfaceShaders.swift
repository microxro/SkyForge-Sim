// SKYFORGE — Apache-2.0
// Procedural airport surface material (round 1 of the 8.2+ push): runway, taxiway and apron pavement that
// replaces the aerial photo inside the aerodrome, so the 0.5 m photo's blur, baked shadows and stretched
// texels never reach the approach camera.
//
// Static MSL functions only (no entry points); spliced into WorldShaders.source ahead of `world_fragment` (see
// docs/rounds/ROUND1.md). Depends on `groundNoise(float2 w, float cell)` from WorldShaders.
//
// Airport mask: `texture2d<float> airportMask [[texture(9)]]` (rg8Unorm over the airport's own rectangle, ~1 m per
// texel, `u.airportRect`). R = pavement coverage (bilinear, antialiased edge); G = class, sampled NEAREST so a
// runway beside a taxiway never blends to a third class. Class values in G (written by the renderer's rasteriser of
// the SFA1 pack, `AirportSurfaces.rasterise`):
//     0.00  not airport (photo ground is kept)
//     0.10  inside the aerodrome boundary but not pavement (infield turf)
//     0.33  apron (concrete or asphalt, parking, fuel hardstands: oil and fuel stains)
//     0.66  taxiway and other pavement
//     1.00  runway
// Pavement classes are dilated one texel in G so the bilinear R edge always has a pavement class under it.

public enum AirportSurfaceShaders {
    public static let source = """
    // MARK: Airport surface (procedural pavement)

    struct AirportSurface {
        float3 albedo;      // linear albedo (replaces the photo outright where `cover` is 1)
        float metallic;     // 0.0 concrete, 0.05 weathered asphalt
        float roughness;    // 0.65 (wet oil, fresh concrete) … 0.85 (rubbered, dry asphalt)
        float2 tilt;        // normal tilt (dh/dx, dh/dy) to subtract from the surface normal's xy
        float cover;        // 1 on pavement, 0 elsewhere (blend the photo albedo with this)
        float infield;      // 1 on aerodrome turf that is not pavement
    };

    static float apSq(float x) { return x * x; }

    /// Class weights from one mask sample: cov = R (bilinear pavement coverage), cls = G (nearest class value).
    /// x apron, y taxiway/other, z runway, w infield turf (any airport texel not covered by pavement).
    static float4 airportClasses(float cov, float cls) {
        float4 k;
        k.x = cov * step(abs(cls - 0.33), 0.08);
        k.y = cov * step(abs(cls - 0.66), 0.08);
        k.z = cov * step(0.92, cls);
        k.w = step(0.03, cls) * (1.0 - saturate(k.x + k.y + k.z));
        return k;
    }

    static float apHash(float2 p) {
        p = fract(p * float2(0.1031, 0.1030));
        p += dot(p, float2(p.y, p.x) + 33.33);
        return fract((p.x + p.y) * p.x);
    }
    static float2 apHash2(float2 p) {
        float a = apHash(p), b = apHash(p + 17.31);
        return float2(a, b);
    }

    /// Cellular noise: x = F1 (distance to the nearest feature point), y = that point's cell id (0…1).
    static float2 apVoronoi(float2 p) {
        float2 i = floor(p), f = fract(p);
        float d1 = 8.0, id = 0.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                float2 g = float2(float(x), float(y));
                float2 o = apHash2(i + g);
                float d = length(g + o - f);
                if (d < d1) { d1 = d; id = apHash(i + g + 91.7); }
            }
        }
        return float2(d1, id);
    }

    /// Triplanar blend of value noise: three axis-aligned projections of the 3D point p weighted by the
    /// normal, so ramps, the crowned runway shoulder and kerbs do not smear the aggregate along one axis.
    static float apTriNoise(float3 p, float3 n, float cell) {
        float3 w = pow(abs(n), float3(4.0));
        w /= max(w.x + w.y + w.z, 1e-4);
        return groundNoise(float2(p.y, p.z), cell) * w.x + groundNoise(float2(p.x, p.z), cell) * w.y
             + groundNoise(float2(p.x, p.y), cell) * w.z;
    }

    /// Distance (m) to the nearest line of a grid of spacing s, per axis (x: across, y: along).
    static float2 apGridDist(float2 q, float2 s) {
        float2 f = abs(fract(q / s + 0.5) - 0.5) * s;
        return f;
    }

    /// Relief height (m) of the pavement at world point p (region metres, axes (ax, perp(ax))): aggregate,
    /// slab joints (concrete: 5 m grooves, a few mm deep; asphalt: transverse cracks every ~18 m and
    /// meandering longitudinal construction seams), and hairline cracks. `o*` are the LOD weights.
    static float apHeight(float2 w, float2 q, float concrete, float3 n, float o1, float o2, float o3, float zc, thread float& cavity) {
        // Aggregate: 4 mm and 1.5 cm grains.
        float h = 0.0020 * apTriNoise(float3(w, zc), n, 0.03125) * o1 + 0.0012 * groundNoise(w + 3.1, 0.0625) * o1
                + 0.0030 * groundNoise(w - 7.3, 0.25) * o2;
        // Joints.
        float2 gd = apGridDist(q, float2(5.0, 5.0));
        float groove = 1.0 - smoothstep(0.0, 0.012, min(gd.x, gd.y));
        // Asphalt: transverse cracks every ~18 m, wandering by up to 1.4 m.
        float wander = 1.4 * groundNoise(float2(q.x * 0.3, 3.0), 1.0);
        float tcrack = 1.0 - smoothstep(0.0, 0.010, abs(fract((q.y + wander) / 18.0 + 0.5) - 0.5) * 18.0);
        // Hairline micro-cracks: iso-lines of low-frequency noise (thin, branching).
        float mc = 1.0 - smoothstep(0.0, 0.018, abs(groundNoise(w + 37.0, 2.0)));
        float mc2 = 1.0 - smoothstep(0.0, 0.012, abs(groundNoise(w + 71.0, 0.5)));
        float cracks = max(mc * 0.7, mc2 * 0.5) * o2;
        // Joint and crack depth only (m, positive): the albedo darkening is built from this, never from the grain.
        cavity = 0.004 * (concrete * groove + (1.0 - concrete) * tcrack * 0.6) * o3 + 0.003 * cracks;
        return h - cavity;
    }

    /// Tyre rubber (0…1) in the touchdown zone. a: m in from the nearer threshold, c: m right of the centreline.
    /// Streaks are stretched noise (long along the runway, ~0.25 m across) in two wheel-track bands at ±3.2 m
    /// and ±6 m from the centreline (main-gear spacing of light and mid-size aircraft), concentrated at ~300 m
    /// and ~450 m from the threshold (aiming point and the second touchdown block), and scaled by `traffic`
    /// (0…1: low-frequency traffic-density mask, e.g. 0.3 GA strip … 1.0 airline runway).
    static float apRubber(float a, float c, float rw, float traffic, float fp) {
        float zone = 0.65 * exp(-apSq((a - 300.0) / 55.0)) + 0.45 * exp(-apSq((a - 450.0) / 75.0))
                   + 0.30 * exp(-apSq((a - 150.0) / 70.0));
        float ac = abs(c);
        float tracks = exp(-apSq((ac - 3.2) / 1.4)) + 0.7 * exp(-apSq((ac - 6.0) / 1.6));
        // Streaks: individual tyre stripes, longer than they are wide; faded when a pixel spans a stripe pair.
        float streak = 0.5 + 0.5 * groundNoise(float2(a * 0.04, c * 3.5) + 5.0, 1.0);
        float patchy = 0.5 + 0.5 * groundNoise(float2(a * 0.02, c * 0.5) - 3.0, 4.0);
        float fine = saturate(1.0 - fp / 0.4);
        float s = mix(0.7, streak, fine) * (0.55 + 0.9 * patchy);
        float dens = zone * tracks * s * traffic;
        // Fades towards the runway edge so the shoulders stay clean.
        dens *= 1.0 - smoothstep(0.38 * rw, 0.5 * rw, ac);
        return saturate(dens);
    }

    /// Oil and fuel stains on aprons: Voronoi cells carry a stain with probability ~35 %; each blotch has an
    /// organic (noise-bent) edge, a dark core, and drip trails towards the cell's low side. Returns 0…1.
    static float apStains(float2 w, float fp, thread float& core) {
        float2 v = apVoronoi(w / 5.5);
        float has = step(0.65, v.y);
        float bend = groundNoise(w + 11.0, 1.0) * 0.18 + groundNoise(w - 5.0, 0.25) * 0.07;
        float edge = (1.0 - smoothstep(0.14, 0.42, v.x + bend));
        float inner = (1.0 - smoothstep(0.04, 0.24, v.x + bend * 0.5));
        // Second, finer scale: fuel drips and small leaks (1.2 m cells).
        float2 v2 = apVoronoi(w / 1.3 + 40.0);
        float has2 = step(0.84, v2.y);
        float drip = (1.0 - smoothstep(0.06, 0.30, v2.x + 0.1 * groundNoise(w + 23.0, 0.25))) * has2;
        float fade = saturate(1.0 - fp / 6.0);
        core = max(inner * has, drip) * fade;
        return max(edge * has * 0.8, drip) * fade;
    }

    /// The full airport pavement material.
    ///  w         region metres (photoW)
    ///  axis      unit vector of the runway direction (runwayA.zw); parallel joints and rubber follow it
    ///  k         class weights from airportClasses(R, G) at this pixel
    ///  tone      the photo's ~64 m mean albedo (linear): picks concrete vs asphalt and the base tone only
    ///  n         shading normal (for the triplanar projection); zc the surface height in region metres
    ///  fp        pixel footprint in metres (length(dfdx(w)) + length(dfdy(w)))
    ///  rwyA/rwyC distance in from the nearer threshold and metres right of the centreline for the primary
    ///            runway (from runwayA/B, as the existing runwayPaint code computes them); rwyValid 0 disables rubber
    ///  rw        runway width (m);  traffic  0…1 traffic density.
    static AirportSurface airportSurface(float2 w, float2 axis, float4 k, float3 tone, float3 n, float zc, float fp,
                                         float rwyA, float rwyC, float rwyValid, float rw, float traffic) {
        AirportSurface s;
        float pave = saturate(k.x + k.y + k.z);
        s.cover = pave;
        s.infield = k.w;
        s.albedo = float3(0.1); s.metallic = 0.05; s.roughness = 0.8; s.tilt = float2(0.0);
        if (pave < 0.002) return s;

        float o1 = saturate(1.0 - fp / 0.05), o2 = saturate(1.0 - fp / 0.45), o3 = saturate(1.0 - fp / 2.5), o4 = saturate(1.0 - fp / 12.0);
        float2 perp = float2(-axis.y, axis.x);
        float2 wr = w - 4096.0 * floor(w / 4096.0);              // wrapped: keeps the 1.5 cm octaves precise far from the origin
        float2 q = float2(dot(w, perp), dot(w, axis));          // across, along the runway axis

        // Concrete or asphalt: aprons lean concrete, runways and taxiways asphalt, and a bright photo flips either.
        float lum = dot(tone, float3(0.2126, 0.7152, 0.0722));
        float concrete = saturate(0.55 * k.x / max(pave, 1e-3) + smoothstep(0.17, 0.30, lum) * 0.9);
        concrete = smoothstep(0.45, 0.6, concrete);

        // Base tone: asphalt 0.055…0.13 (weathered, lightened with age), concrete 0.30…0.45, with 64 m and 8 m
        // patch variation (resurfaced strips) but none of the photo's high frequencies.
        float age = 0.5 + 0.5 * groundNoise(w + 9.0, 64.0);
        float patchTone = groundNoise(w - 13.0, 8.0) * o4;
        float baseA = mix(0.060, 0.125, saturate(age * 0.7 + (lum - 0.08) * 2.0)) * (1.0 + 0.10 * patchTone);
        float baseC = mix(0.30, 0.44, age) * (1.0 + 0.06 * patchTone);
        float base = mix(baseA, baseC, concrete);

        // Per-slab tone on concrete (each 5 m slab differs by a few percent), a faint warm tint on asphalt.
        float2 slab = floor(q / 5.0);
        float slabTone = (apHash(slab + 3.0) - 0.5) * 0.10 * concrete * o4 + (apHash(slab * 0.37) - 0.5) * 0.04 * concrete;

        float cav = 0.0, cavX = 0.0, cavY = 0.0;
        float h0 = apHeight(w, q, concrete, n, o1, o2, o3, zc, cav);
        // Normal tilt from two finite-difference taps, only while a pixel is small enough to see the relief.
        if (fp < 6.0) {
            float e = max(0.02, fp * 0.5);
            float2 dx = float2(e, 0.0), dy = float2(0.0, e);
            float hx = apHeight(w + dx, q + float2(dot(dx, perp), dot(dx, axis)), concrete, n, o1, o2, o3, zc, cavX);
            float hy = apHeight(w + dy, q + float2(dot(dy, perp), dot(dy, axis)), concrete, n, o1, o2, o3, zc, cavY);
            s.tilt = float2(hx - h0, hy - h0) / e;
        }

        // Aggregate speckle in the albedo (±8 % at the 5 mm scale), dark crack lines, slab joints.
        float agg = apTriNoise(float3(wr, zc), n, 0.015625) * o1 + groundNoise(w + 5.0, 0.0625) * o2 * 0.6;
        float albedoMod = 1.0 + 0.08 * agg + 0.07 * groundNoise(w - 21.0, 1.0) * o3 + slabTone;
        float3 tint = mix(float3(1.0, 0.99, 0.97), float3(0.97, 0.98, 1.02), 1.0 - concrete);
        float3 col = float3(base) * albedoMod * tint;
        // Joint and crack darkening from the height map (valleys 4 mm deep read as dark lines).
        float valley = saturate(cav / 0.004);
        col *= 1.0 - 0.35 * valley;
        // Joint sealant: concrete joints are filled with dark tar-like sealant.
        float2 gd = apGridDist(q, float2(5.0, 5.0));
        float jointLine = 1.0 - smoothstep(0.012, 0.012 + max(fp, 0.02), min(gd.x, gd.y));
        col *= 1.0 - 0.45 * jointLine * concrete * saturate(1.0 - fp / 3.0);
        // Far field: joints collapse into a faint grid tone so they do not alias.
        col *= 1.0 - 0.04 * concrete * saturate((fp - 1.0) / 4.0) * saturate(1.0 - fp / 30.0);

        float rough = mix(0.84, 0.70, concrete);
        float metallic = mix(0.05, 0.0, concrete);
        rough += 0.03 * groundNoise(w + 2.0, 4.0) * o4;

        // Touchdown-zone rubber (runway class, primary runway frame only).
        float rub = 0.0;
        if (rwyValid > 0.5 && k.z > 0.01) {
            rub = apRubber(rwyA, rwyC, rw, traffic, fp) * k.z;
            col *= 1.0 - 0.60 * rub;                    // black rubber, strongest at the streak cores
            col = mix(col, col * float3(0.92, 0.93, 0.96), rub);   // slightly cool, oily-black
            rough = mix(rough, 0.86, rub);              // rubber is matt
            // Thin raised rubber film tilts the normal a hair: slightly gloss-free, so only the tilt noise.
            s.tilt += float2(groundNoise(float2(rwyA * 0.5, rwyC * 6.0), 0.5), groundNoise(float2(rwyA * 0.5, rwyC * 6.0) + 9.0, 0.5)) * (0.015 * rub * o2);
        }

        // Oil and fuel on aprons (and, fainter, on taxiways near gates).
        float core = 0.0;
        float st = 0.0;
        if (k.x > 0.02) {
            st = apStains(w, fp, core) * (k.x + 0.25 * k.y);
            core *= k.x + 0.25 * k.y;
        }
        float3 oil = mix(float3(0.030, 0.026, 0.022), float3(0.020, 0.024, 0.030), apHash(floor(w / 5.5)));   // brown-black / blue-black
        col = mix(col, col * 0.55, st * 0.6);
        col = mix(col, oil * (1.0 + 0.2 * groundNoise(w + 31.0, 0.0625)), core * 0.55);
        rough = mix(rough, 0.65, saturate(core + st * 0.3));           // slick fuel and oil

        s.albedo = max(col, float3(0.012));
        s.metallic = metallic;
        s.roughness = clamp(rough, 0.65, 0.85);
        return s;
    }

    /// Multiplicative turf detail for the aerodrome infield (mean ≈ 1): 9 m mowing stripes (±3.5 %) and fine clumps, laid
    /// over the tuned photo-ground path rather than replacing it. Fades by pixel footprint.
    static float3 airportInfieldDetail(float2 w, float fp) {
        float o1 = saturate(1.0 - fp / 0.15), o2 = saturate(1.0 - fp / 0.6), o4 = saturate(1.0 - fp / 8.0);
        float stripe = 0.5 + 0.5 * sin(dot(w, float2(0.8, 0.6)) / 9.0 * 3.14159265);
        float v = 1.0 + 0.035 * (stripe - 0.5) * 2.0 * o4 + 0.10 * groundNoise(w + 5.3, 0.25) * o1 + 0.08 * groundNoise(w - 9.1, 1.0) * o2;
        return float3(v);
    }

    /// Mown aerodrome infield (inside the boundary, off the pavement): the photo is not used. 9 m mowing
    /// stripes, clumps, and the photo's 64 m mean only as a hue anchor.
    static float3 airportInfield(float2 w, float3 tone, float fp) {
        float o1 = saturate(1.0 - fp / 0.15), o2 = saturate(1.0 - fp / 0.6), o4 = saturate(1.0 - fp / 8.0);
        float3 g = float3(0.105, 0.150, 0.062);
        float lum = dot(tone, float3(0.2126, 0.7152, 0.0722));
        g *= clamp(lum / 0.12, 0.7, 1.35);
        float stripe = 0.5 + 0.5 * sin(dot(w, float2(0.8, 0.6)) / 9.0 * 3.14159265);
        g *= 1.0 + 0.035 * (stripe - 0.5) * 2.0 * o4;
        g *= 1.0 + 0.14 * groundNoise(w + 5.3, 0.25) * o1 + 0.12 * groundNoise(w - 9.1, 1.0) * o2 + 0.10 * groundNoise(w + 23.0, 6.0) * o4;
        return g;
    }
    """
}
