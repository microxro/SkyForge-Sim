// SKYFORGE — Apache-2.0
// Ocean and lake shading library: multi-octave Gerstner waves (Finch, "Effective Water Simulation from
// Physical Models", GPU Gems 2004) with analytic normals, Schlick Fresnel, Beer-Lambert depth absorption,
// wave-crest subsurface scattering (after Tessendorf / Jensen-style approximations), GGX-like sun glitter
// from the wave slope variance, shoreline and whitecap foam, and wake foam from aircraft on the water.
// Pure functions, all prefixed `ow`, no entry points: concatenate after WorldShaders.source and call
// `owShade` from the water branch. The CPU twin is OceanWaves.swift (same constants, tested on Linux).

public enum OceanShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;
    constant float owAngleTable[16] = {-0.95, 0.8012, -0.8413, 0.1106, -0.2399, -0.0884, 0.2396, -0.6354, -0.3247, 0.0753, 0.8959, 0.6103, -0.6098, 0.9408, 0.6004, -0.1105};

    // One wake source (an aircraft or boat on the water). Packed as two float4s.
    struct OWWake {
        float4 posRadius;    // xy world position (m), z heading (rad, travel direction), w half-width (m)
        float4 params;       // x speed (m/s), y length behind (m), z intensity 0...1, w age-fade 0...1
    };

    struct OWParams {
        float time;          // seconds
        float windSpeed;     // m/s at 10 m
        float windDir;       // radians, direction the wind blows toward
        float choppy;        // 0...1 Gerstner steepness scale
        int   octaves;       // 1...8 (tier knob)
        int   wakeCount;    // 0...8
        float2 pad;
    };

    struct OWOut {
        float3 colour;       // linear HDR radiance leaving the surface toward the eye
        float3 normal;       // shading normal, z up
        float  foam;         // 0...1 total foam coverage (for the caller's masks)
    };

    // MARK: noise
    static float owHash(float2 p) {
        p = fract(p * float2(0.1031, 0.1030));
        float3 q = float3(p.x, p.y, p.x) ;
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }
    static float owNoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = owHash(i), b = owHash(i + float2(1.0, 0.0));
        float c = owHash(i + float2(0.0, 1.0)), d = owHash(i + float2(1.0, 1.0));
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }
    static float owFbm(float2 p) {
        float s = 0.0, a = 0.5;
        for (int i = 0; i < 4; i++) { s += a * owNoise(p); p = p * 2.03 + 17.0; a *= 0.5; }
        return s;
    }

    // MARK: Gerstner waves
    // Wave i of N: wavelength L0 * 0.62^i (L0 from wind speed: the fully developed sea's dominant length
    // 2*pi*U^2/g * 0.14), direction spread around the wind by a fixed per-wave hash, deep-water dispersion
    // omega = sqrt(g k), amplitude ~ Phillips-like k^-1.2 falloff.
    constant float OW_G = 9.81;

    static float owWaveAngle(int i) { return owAngleTable[i & 15]; }

    // Returns the surface slope (dh/dx, dh/dy) and, through `height`/`crest`, the height and the Jacobian-style
    // crest measure (1 = sharp crest, 0 = trough). `footprint` is the pixel size in metres: octaves
    // shorter than 2.5 pixels fade out so distant water calms instead of aliasing.
    static float2 owGerstnerSlope(float2 p, float t, constant OWParams& P, float footprint,
                                  thread float& height, thread float& crest) {
        float L0 = clamp(0.14 * 6.2832 * P.windSpeed * P.windSpeed / OW_G, 12.0, 220.0);
        float2 slope = float2(0.0);
        float h = 0.0, pinch = 0.0;
        float amp0 = clamp(0.0036 * P.windSpeed * P.windSpeed / 10.0, 0.05, 2.2);
        for (int i = 0; i < 8; i++) {
            if (i >= P.octaves) break;
            float L = L0 * pow(0.62, float(i));
            float fade = saturate(1.0 - footprint * 2.5 / L);
            if (fade <= 0.0) continue;
            float k = 6.2832 / L;
            float ang = P.windDir + owWaveAngle(i) * (0.55 + 0.15 * float(i));
            float2 d = float2(cos(ang), sin(ang));
            float w = sqrt(OW_G * k);
            float A = amp0 * pow(L / L0, 1.2) * fade;
            float ph = k * dot(d, p) - w * t + float(i) * 1.7;
            float s = sin(ph), c = cos(ph);
            h += A * s;
            slope += d * (A * k * c);
            // Steepness Q*k*A < 1 keeps loops out; pinch accumulates the horizontal compression at crests.
            float q = min(P.choppy / max(k * A * float(P.octaves), 1e-3), 1.0);
            pinch += q * k * A * s;
        }
        height = h;
        crest = saturate(pinch * 1.4 + 0.5);
        return slope;
    }

    // Normal-map detail: two scrolling ripple layers (capillary waves) below the Gerstner band.
    static float2 owRippleSlope(float2 p, float t, float footprint, float wind) {
        float fade = saturate(1.0 - footprint * 2.5 / 0.9) * saturate(wind / 6.0);
        if (fade <= 0.0) return float2(0.0);
        float2 q1 = p * 1.7 + float2(t * 0.35, t * 0.21);
        float2 q2 = p * 3.1 - float2(t * 0.27, -t * 0.43) + 41.0;
        float e = 0.08;
        float2 s1 = float2(owNoise(q1 + float2(e, 0.0)) - owNoise(q1 - float2(e, 0.0)),
                           owNoise(q1 + float2(0.0, e)) - owNoise(q1 - float2(0.0, e)));
        float2 s2 = float2(owNoise(q2 + float2(e, 0.0)) - owNoise(q2 - float2(e, 0.0)),
                           owNoise(q2 + float2(0.0, e)) - owNoise(q2 - float2(0.0, e)));
        return (s1 * 0.55 + s2 * 0.35) * fade;
    }

    // MARK: optics
    static float owFresnel(float cosT) {
        float x = saturate(1.0 - cosT);
        float x2 = x * x;
        return 0.02 + 0.98 * x2 * x2 * x;                // Schlick, water n = 1.33 -> F0 = 0.02
    }

    // Beer-Lambert: transmittance of the water column per channel (red dies first).
    static float3 owTransmittance(float depth) {
        const float3 sigma = float3(0.45, 0.075, 0.032); // 1/m, clear ocean-ish
        return exp(-sigma * max(depth, 0.0));
    }

    // Colour of the water column over a bottom of albedo `bed`, lit by `light` (irradiance), `depth` metres.
    // Deep water tends to the in-scatter colour; shallows show the bed.
    static float3 owDepthColour(float depth, float3 bed, float3 light, float3 deepTint) {
        float3 T = owTransmittance(depth * 2.0);        // down and back up
        float3 inscatter = deepTint * light * (1.0 - owTransmittance(depth));
        return bed * light * T + inscatter;
    }

    // Subsurface glow through thin wave crests lit from behind (light travels through the crest toward the eye).
    static float3 owCrestSSS(float3 viewDir, float3 toSun, float3 n, float crest, float height,
                             float3 sunRadiance, float3 tint) {
        float back = pow(saturate(dot(viewDir, toSun) * 0.5 + 0.5), 4.0);   // view looking toward the sun side
        float thin = saturate(crest * 1.3 - 0.35) * saturate(0.5 + height * 0.6);
        float wrap = saturate(dot(n, toSun) * 0.5 + 0.5);
        return tint * sunRadiance * (back * thin * wrap * 0.9 + 0.06 * thin);
    }

    // Sun glitter: a Beckmann lobe on the macro normal with roughness from the slope variance, so it
    // widens with wind and survives at distance (no single-pixel fireflies: capped).
    static float owGlitter(float3 viewDir, float3 toSun, float3 n, float slopeVar) {
        float3 hv = normalize(toSun - viewDir);
        float nh = saturate(dot(n, hv));
        float m2 = clamp(slopeVar, 0.0006, 0.25);
        float t2 = (1.0 - nh * nh) / max(nh * nh, 1e-4);
        float D = exp(-t2 / m2) / (3.14159 * m2 * nh * nh * nh * nh + 1e-4);
        return min(D * 0.08 * saturate(toSun.z * 4.0), 14.0);
    }

    // MARK: foam
    // Whitecaps: crest measure beyond a wind-dependent threshold, broken up by noise.
    static float owWhitecap(float2 p, float crest, float wind, float footprint) {
        float thr = mix(0.97, 0.72, saturate((wind - 6.0) / 14.0));   // fewer, real whitecaps: at 8 m/s the old 0.83 speckled the whole surface
        float lace = owFbm(p * 0.9 + 3.0) * 0.6 + owFbm(p * 3.7) * 0.4;
        float f = smoothstep(thr, thr + 0.18, crest + (lace - 0.5) * 0.35);
        return f * saturate(1.2 - footprint * 0.15);
    }

    // Shoreline foam: `shoreDist` is 0 at the waterline and grows seaward (m). Waves push the band in and out.
    static float owShoreFoam(float2 p, float shoreDist, float t, float footprint) {
        float swash = 1.2 + 0.9 * sin(t * 0.7 + p.x * 0.05 + p.y * 0.03);
        float edge = 1.0 - smoothstep(0.0, swash * 2.5, shoreDist);
        float lace = smoothstep(0.35, 0.75, owFbm(p * 1.3 + t * 0.05));
        float trailing = (1.0 - smoothstep(swash * 2.5, swash * 6.0, shoreDist)) * 0.35
                         * smoothstep(0.5, 0.8, owFbm(p * 0.6 - t * 0.03 + 9.0));
        return saturate((edge * (0.55 + 0.45 * lace) + trailing) * saturate(1.3 - footprint * 0.12));
    }

    // Wake foam from up to 8 sources: a V of two arms plus a turbulent centre trail, widening and decaying
    // behind each source. Also writes the surface-slope perturbation through `slopeOut`.
    static float owWakeFoam(float2 p, float t, constant OWWake* wakes, int count, thread float2& slopeOut) {
        float foam = 0.0;
        for (int i = 0; i < 8; i++) {
            if (i >= count) break;
            OWWake w = wakes[i];
            float2 rel = p - w.posRadius.xy;
            float2 fwd = float2(cos(w.posRadius.z), sin(w.posRadius.z));
            float2 side = float2(-fwd.y, fwd.x);
            float along = -dot(rel, fwd);                 // metres behind the source
            float across = dot(rel, side);
            float len = max(w.params.y, 1.0);
            if (along < -w.posRadius.w || along > len) continue;
            float u = saturate(along / len);              // 0 at the source, 1 at the tail
            float spread = w.posRadius.w * (1.0 + 2.2 * u);
            float arm = abs(abs(across) - spread * 0.9);  // Kelvin-like arms
            float armFoam = (1.0 - smoothstep(0.0, 0.25 * spread + 0.3, arm)) * (1.0 - u);
            float centre = (1.0 - smoothstep(0.0, spread * 0.8, abs(across))) * pow(1.0 - u, 1.5);
            float n = owFbm(float2(along * 0.35, across * 0.5) + float2(t * 0.1, 0.0) + float(i) * 7.0);
            float f = (armFoam * 0.8 + centre * 0.9) * smoothstep(0.25, 0.65, n + 0.25 * (1.0 - u));
            f *= saturate(along / max(w.posRadius.w, 0.5) + 1.0) * w.params.z * w.params.w;
            foam = max(foam, f);
            // Ripples radiating from the arms.
            float ph = (along * 1.6 - across * 0.0) - t * 3.0;
            slopeOut += side * (sin(ph) * 0.12 * armFoam * w.params.z) * sign(across);
        }
        return saturate(foam);
    }

    // MARK: composition
    // Shades one water pixel.
    //   p          world xy (m); dir  unit view direction camera->surface (z up); toSun unit
    //   depth      water depth below the surface (m; use a big number for open ocean)
    //   shoreDist  metres from the waterline (large for open water)
    //   bed        bottom albedo (sand ~ 0.35,0.3,0.22)
    //   skyEnv     sky radiance the caller sampled along reflect(dir, n) is supplied via `skyRefl`
    //              (the caller calls owWaveNormal first if it must sample the sky itself)
    //   sunRad     sun radiance (colour * intensity), ambient sky irradiance-ish colour
    static float3 owWaveNormal(float2 p, constant OWParams& P, float footprint,
                               thread float& height, thread float& crest, thread float& slopeVar) {
        float2 s = owGerstnerSlope(p, P.time, P, footprint, height, crest);
        s += owRippleSlope(p, P.time, footprint, P.windSpeed);
        slopeVar = 0.0008 + 0.0042 * saturate(P.windSpeed / 20.0) + dot(s, s) * 0.2;
        return normalize(float3(-s, 1.0));
    }

    static OWOut owShade(float2 p, float3 dir, float3 toSun, constant OWParams& P, constant OWWake* wakes,
                         float footprint, float depth, float shoreDist, float3 bed,
                         float3 skyRefl, float3 sunRad, float3 ambient, float sunVis, float lake) {
        float height, crest, slopeVar;
        float3 n = owWaveNormal(p, P, footprint, height, crest, slopeVar);
        float2 wakeSlope = float2(0.0);
        float wake = owWakeFoam(p, P.time, wakes, P.wakeCount, wakeSlope);
        n = normalize(n + float3(-wakeSlope, 0.0));
        float cosT = max(0.0, -dot(dir, n));
        // Imagery lakes (lake = 1): a reflectance floor and a wider glint lobe, so the sky and sun show on flat water.
        // The ocean (lake = 0) keeps the physical Fresnel and slope variance.
        float F = max(owFresnel(cosT), 0.10 * lake);
        slopeVar += 0.12 * lake;

        float3 light = ambient * 0.5 + sunRad * max(0.0, toSun.z) * 0.18 * sunVis;
        float3 body = owDepthColour(depth, bed, light, float3(0.004, 0.026, 0.034));   // darker deep-water tint
        body += owCrestSSS(dir, toSun, n, crest, height, sunRad * sunVis, float3(0.02, 0.14, 0.10));

        float3 col = mix(body, skyRefl, F);
        col += sunRad * sunVis * owGlitter(dir, toSun, n, slopeVar) * F * 10.0;     // stronger sun glint

        float foam = max(owWhitecap(p, crest, P.windSpeed, footprint), owShoreFoam(p, shoreDist, P.time, footprint));
        foam = max(foam, wake);
        float3 foamCol = float3(0.90, 0.93, 0.94) * (ambient * 0.9 + sunRad * max(0.0, toSun.z) * 0.5 * sunVis);
        col = mix(col, foamCol, foam * 0.6);

        OWOut o; o.colour = col; o.normal = n; o.foam = foam;
        return o;
    }
    """
}
