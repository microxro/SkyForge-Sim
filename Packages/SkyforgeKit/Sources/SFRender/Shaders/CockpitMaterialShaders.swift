// SKYFORGE — Apache-2.0
// Round 4: cockpit materials. Anisotropic brushed metal (bezel rings, throttle quadrant, switch guards,
// yoke shafts), a two-surface canopy glass pass (inner and outer Fresnel, ghost reflection from the second
// surface, dust film, scratches), and the shared maths for the cockpit contact-shadow pass.
//
// Usage: `CloudShaders.common + WorldShaders.source + CockpitMaterialShaders.source` is ONE Metal library.
// Part 1 ("ck_" functions) depends only on metal_stdlib, so it is unit-testable off-device (see
// tools/cockpit_check/). Part 2 (glue) uses WorldUniforms, WorldVarying, Skin, fuselageSkin, shadowVisibility
// and skyEnv from WorldShaders, and must be appended after it. Integration steps: docs/rounds/ROUND4.md.
//
// Frames: body axes are x forward, y right, z down (as Cockpit.swift). Rendered vectors (normals, view) are
// camera-relative world; `ck_bodyToWorld` converts with the model matrix's rotation columns.

public enum CockpitMaterialShaders {
    public static let source = """
    // ===================================================================================================
    // Part 1: pure functions (no WorldShaders dependency)
    // ===================================================================================================
    #include <metal_stdlib>
    using namespace metal;

    constant float CK_PI = 3.14159265358979;

    static float ck_hash(float2 p) {
        p = fract(p * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return fract((p.x + p.y) * p.x);
    }
    /// Value noise in −1…1.
    static float ck_vnoise(float2 x) {
        float2 i = floor(x), f = fract(x);
        float2 w = f * f * (3.0 - 2.0 * f);
        float a = ck_hash(i), b = ck_hash(i + float2(1, 0)), c = ck_hash(i + float2(0, 1)), d = ck_hash(i + float2(1, 1));
        return mix(mix(a, b, w.x), mix(c, d, w.x), w.y) * 2.0 - 1.0;
    }

    // ---- Anisotropic GGX (Burley 2012 / Heitz 2014) -------------------------------------------------------
    // Convention: `t` is the direction of the brushing grooves. Grooves along t make the micro-normals vary
    // across them, so the surface is rougher along b = n × t and the highlight is stretched along b, i.e.
    // perpendicular to the brushing (as real brushed steel and aluminium look).

    /// Roughness (perceptual, 0…1) and anisotropy (0 = isotropic … 0.95) → alphas along t and b.
    static float2 ck_alphas(float rough, float aniso) {
        float a = max(rough * rough, 0.002);
        aniso = clamp(aniso, 0.0f, 0.95f);
        return float2(max(a * (1.0 - aniso), 0.002), max(a * (1.0 + aniso), 0.002));
    }

    /// Normal distribution; th, bh, nh = h·t, h·b, h·n. ∫ D(h) (h·n) dω_h = 1 over the hemisphere (checked in
    /// tools/cockpit_check/aniso_check.cpp).
    static float ck_D(float th, float bh, float nh, float2 a) {
        float x = th / a.x, y = bh / a.y;
        float d = x * x + y * y + nh * nh;
        return 1.0 / (CK_PI * a.x * a.y * d * d);
    }
    /// Smith Λ for the anisotropic GGX (Heitz 2014, eq. 80).
    static float ck_lambda(float tw, float bw, float nw, float2 a) {
        float nn = max(abs(nw), 1e-4f);
        return 0.5 * (sqrt(1.0 + (a.x * a.x * tw * tw + a.y * a.y * bw * bw) / (nn * nn)) - 1.0);
    }
    /// Height-correlated Smith masking-shadowing.
    static float ck_G2(float3 t, float3 b, float3 n, float3 v, float3 l, float2 a) {
        return 1.0 / (1.0 + ck_lambda(dot(v, t), dot(v, b), dot(v, n), a) + ck_lambda(dot(l, t), dot(l, b), dot(l, n), a));
    }
    /// Specular BRDF × (n·l) for a conductor of Fresnel reflectance `f0` (its albedo). v, l point away from
    /// the surface.
    static float3 ck_anisoSpecular(float3 n, float3 t, float3 v, float3 l, float rough, float aniso, float3 f0) {
        float nl = dot(n, l), nv = dot(n, v);
        if (nl <= 0.0 || nv <= 0.0) return float3(0.0);
        float3 b = cross(n, t);
        float3 h = normalize(l + v);
        float2 a = ck_alphas(rough, aniso);
        float D = ck_D(dot(h, t), dot(h, b), dot(h, n), a);
        float G = ck_G2(t, b, n, v, l, a);
        float vh = saturate(dot(v, h));
        float3 F = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
        return F * (D * G / (4.0 * nv));        // D·G·F / (4·nl·nv) × nl
    }
    /// Reflection vector bent toward the grain (Filament, "Anisotropic specular reflection"): the sky is
    /// smeared across the brushing, so a bezel catches a broad band of sky instead of a mirror image.
    static float3 ck_bentReflect(float3 n, float3 t, float3 v, float aniso) {
        float3 an = cross(t, v);
        float3 bent = cross(an, t);
        float bl = dot(bent, bent);
        bent = bl > 1e-8f ? bent * rsqrt(bl) : n;                  // v parallel to t: no bend (normalize(0) is NaN)
        bent = normalize(mix(n, bent, clamp(aniso, 0.0f, 0.95f)));
        return reflect(-v, bent);
    }

    // ---- Brushing direction -------------------------------------------------------------------------------

    /// Gram–Schmidt: `t` made perpendicular to `n` (falls back to `fallback` when degenerate).
    static float3 ck_ortho(float3 n, float3 t, float3 fallback) {
        float3 r = t - n * dot(n, t);
        float l2 = dot(r, r);
        if (l2 < 1e-8) { r = fallback - n * dot(n, fallback); l2 = max(dot(r, r), 1e-8f); }
        return r * rsqrt(l2);
    }

    /// Direction in the tangent plane along which the interpolated normal does not change: the axis of a
    /// tube (yoke shaft, throttle lever, switch guard rail). Needs smooth per-vertex normals; `confidence`
    /// is 0 on flat faces, where the caller uses its fallback. dpx, dpy: d(position)/dx,dy; dnx, dny: the same
    /// for the unit normal.
    static float3 ck_axisFromCurvature(float3 n, float3 dpx, float3 dpy, float3 dnx, float3 dny, float3 fallback,
                                       thread float& confidence) {
        float g11 = dot(dnx, dnx), g22 = dot(dny, dny), g12 = dot(dnx, dny);
        float tr = g11 + g22, det = sqrt(max((g11 - g22) * (g11 - g22) + 4.0 * g12 * g12, 0.0f));
        float lmax = 0.5 * (tr + det), lmin = 0.5 * (tr - det);
        float th = 0.5 * atan2(2.0 * g12, g11 - g22) + 0.5 * CK_PI;          // eigenvector of the smaller eigenvalue
        float3 ax = dpx * cos(th) + dpy * sin(th);
        float curv = lmax / max(dot(dpx, dpx) + dot(dpy, dpy), 1e-12f);       // ≈ 1 / r² for a tube of radius r
        float cyl = (lmax - lmin) / max(lmax + lmin, 1e-12f);                 // 1 for a cylinder, 0 for a sphere
        confidence = smoothstep(4.0, 64.0, curv) * smoothstep(0.55, 0.9, cyl);
        return ck_ortho(n, ax, fallback);
    }

    /// Gauge centres in panel (y, z) body metres, mirrored from Cockpit.mesh(): 3 × 2 engine and flight
    /// instruments and the two small ones at the left. KEEP IN SYNC with Cockpit.swift.
    constant float2 CK_GAUGES[8] = { float2(-0.035, -0.305), float2(0.075, -0.305), float2(0.185, -0.305),
                                     float2(-0.035, -0.175), float2(0.075, -0.175), float2(0.185, -0.175),
                                     float2(-0.475, -0.295), float2(-0.475, -0.195) };
    constant float CK_PANEL_TILT = 0.20943951;        // Cockpit.screenTilt (12°)

    /// Nearest gauge centre to a panel point and the distance to it.
    static float ck_nearestGauge(float2 yz, thread float2& centre) {
        float best = 1e9;
        centre = CK_GAUGES[0];
        for (int i = 0; i < 8; i++) {
            float d = length(yz - CK_GAUGES[i]);
            if (d < best) { best = d; centre = CK_GAUGES[i]; }
        }
        return best;
    }
    /// Circular brushing direction (body axes) of a spun bezel ring at body point `L`, or 0 when `L` is not on
    /// a gauge ring (then `onRing` = 0).
    static float3 ck_ringTangentBody(float3 L, thread float& onRing) {
        float2 c;
        float d = ck_nearestGauge(L.yz, c);
        onRing = 1.0 - smoothstep(0.052, 0.058, d);                 // outer radius of the widest ring is 0.0533
        float2 dyz = L.yz - c;
        float3 radial = normalize(float3(-tan(CK_PANEL_TILT) * dyz.y, dyz.x, dyz.y) + float3(1e-6, 0.0, 0.0));
        float3 pn = float3(-cos(CK_PANEL_TILT), 0.0, -sin(CK_PANEL_TILT));
        return normalize(cross(pn, radial));
    }

    /// Fine brushing: stretched value noise, `across` and `along` the grooves in metres, `fp` the pixel
    /// footprint (m). Returns −1…1; fades to 0 once grooves (~0.5 mm) are under-sampled.
    static float ck_brush(float across, float along, float fp) {
        float n = ck_vnoise(float2(across * 2200.0, along * 70.0)) * 0.6 + ck_vnoise(float2(across * 5200.0 + 17.0, along * 140.0)) * 0.4;
        return n * saturate(1.0 - fp / 0.0006);
    }

    /// Brushed conductor shading. `n`, `t`, `v` in one frame, `l` toward the sun; `sun` radiance × visibility,
    /// `env` the sky colour already looked up along `ck_bentReflect`, `ambient` the cabin fill.
    static float3 ck_brushedMetal(float3 n, float3 t, float3 v, float3 l, float3 f0, float rough, float aniso,
                                  float3 sun, float3 env, float3 ambient, float occlusion) {
        float nv = clamp(dot(n, v), 1e-3f, 1.0f);       // pow() of a negative base is NaN
        float3 spec = ck_anisoSpecular(n, t, v, l, rough, aniso, f0) * sun;
        float3 F = f0 + (1.0 - f0) * pow(1.0 - nv, 5.0);
        // Rough metal loses its mirror image; the bent reflection keeps the broad anisotropic band.
        float3 envSpec = env * F * (1.0 - 0.55 * rough) * occlusion;
        float3 fill = f0 * ambient * 0.10 * occlusion;                // multiple scattering the single-bounce lobe lacks
        return spec + envSpec + fill;
    }

    // ---- Canopy glass --------------------------------------------------------------------------------------

    /// Fresnel for glass (n = 1.52, F0 = 0.043).
    static float ck_fresnelGlass(float nv) { return 0.043 + 0.957 * pow(1.0 - saturate(nv), 5.0); }

    /// Lateral displacement (m) of a ray crossing a flat plate of thickness `t` at incidence cosθ = `nv`. A
    /// parallel plate does not turn rays, so a far scene does not shift; the displacement shows only in the
    /// ghost reflection off the second surface, which is offset by twice this.
    static float ck_plateShift(float nv, float t) {
        float s2 = 1.0 - nv * nv;
        float sinI = sqrt(max(s2, 0.0f));
        return t * sinI * (1.0 - nv / sqrt(max(1.52 * 1.52 - s2, 1e-3f)));
    }

    /// Henyey–Greenstein phase function.
    static float ck_hg(float c, float g) {
        float d = 1.0 + g * g - 2.0 * g * c;
        return (1.0 - g * g) / (4.0 * CK_PI * d * sqrt(d));
    }

    /// Radiance the cabin presents to the glass along a reflection direction in body axes (x fwd, z down):
    /// the dark glare shield and panel below the horizon, the light headliner above, side trim around.
    /// `shieldSun` = 0…1 sun on the glare shield.
    static float3 ck_cabinRadiance(float3 rb, float3 ambient, float3 sun, float shieldSun) {
        float down = smoothstep(0.02, 0.40, rb.z);                    // looking at shield and panel
        float up = 1.0 - smoothstep(-0.55, -0.05, rb.z);                    // looking at the headliner
        float3 shield = float3(0.028, 0.028, 0.030) * 1.9 * (ambient + sun * 0.30 * shieldSun);   // Cockpit.swift shield colour
        float3 liner = float3(0.38, 0.37, 0.34) * 0.55 * ambient;
        float3 trim = float3(0.12, 0.11, 0.10) * ambient;
        return mix(trim, mix(shield, shield * 1.4, saturate(rb.x)), down) * (1.0 - up) + liner * up;
    }

    /// Film of dust on the glass in 0…1 (density × coverage), dirtier toward the panel and in the corners.
    /// `p` = glass point in body axes, `fp` pixel footprint in metres.
    static float ck_dustFilm(float3 p, float fp, float amount) {
        float2 q = p.yz;
        float patch = 0.5 + 0.5 * (0.6 * ck_vnoise(q * 3.1 + 5.0) + 0.4 * ck_vnoise(q * 11.0 - 3.0));    // smears, wipes
        float settle = 0.55 + 0.45 * smoothstep(-0.35, 0.10, p.z);           // heavier low on the screen
        // Speckle: ~1.2 mm particles.
        float2 cell = q / 0.0012;
        float2 ci = floor(cell), cf = fract(cell) - 0.5;
        float on = step(0.62, ck_hash(ci));
        float speck = on * (1.0 - smoothstep(0.18, 0.5, length(cf))) * saturate(1.0 - fp / 0.003);
        float haze = 0.06 + 0.12 * patch;                                   // microscopic film that fades with distance
        return saturate(amount * (haze * settle + 0.55 * speck * patch));
    }

    /// One layer of scratches on the glass plane: random-direction hairlines in cells of `s` metres. Returns 0…1.
    static float ck_scratchLayer(float2 q, float s, float fp, float seed) {
        float2 cell = q / s;
        float2 ci = floor(cell), cf = fract(cell);
        float present = step(0.62, ck_hash(ci + seed));
        float ang = ck_hash(ci + seed + 19.0) * CK_PI;
        float2 dir = float2(cos(ang), sin(ang));
        float2 c0 = float2(ck_hash(ci + seed + 3.0), ck_hash(ci + seed + 7.0));
        float2 d = (cf - c0) * s;
        float along = dot(d, dir), perp = abs(dot(d, float2(-dir.y, dir.x)));
        float len = (0.25 + 0.6 * ck_hash(ci + seed + 11.0)) * s;
        float w = max(0.00012, fp * 0.7);
        float line = (1.0 - smoothstep(0.0, w, perp)) * (1.0 - smoothstep(len * 0.8, len, abs(along)));
        return present * line * saturate(0.00012 / w);                       // keep energy as the line goes sub-pixel
    }
    /// Wiper-sweep micro-scratches: concentric arcs about a pivot (y, z body metres), within the swept sector.
    static float ck_wiperArcs(float2 q, float2 pivot, float fp) {
        float2 d = q - pivot;
        float r = length(d);
        float ang = atan2(d.x, -d.y);                                         // 0 = straight up the screen
        float sweep = 1.0 - smoothstep(0.55, 0.75, abs(ang));
        float band = smoothstep(0.28, 0.35, r) * (1.0 - smoothstep(0.80, 0.90, r));
        float idx = floor(r * 900.0);
        float on = step(0.88, ck_hash(float2(idx, 4.0)));
        float w = max(0.00008, fp * 0.7);
        float dd = abs(fract(r * 900.0) - 0.5) / 900.0;
        float arc = on * (1.0 - smoothstep(0.0, w, dd)) * saturate(0.00008 / w);
        return arc * sweep * band * (0.5 + 0.5 * ck_vnoise(float2(r * 40.0, 2.0)));
    }

    struct CKGlassOut { float3 rgb; float alpha; };

    /// Dual-surface canopy glass, written for premultiplied blending over the world already drawn behind it:
    /// result = rgb + dst × (1 − alpha), with alpha = 1 − transmittance.
    ///   n        outward normal, v the unit vector from the glass to the eye (both camera-relative world)
    ///   toSun    unit vector to the sun, sunRad its radiance × visibility
    ///   rbRefl   the reflection direction into the cabin, in body axes; ambient the cabin fill
    ///   p        glass point in body axes, fp pixel footprint (m)
    ///   dust, scratches in 0…1 (0 = clean, 1 = a neglected trainer)
    static CKGlassOut ck_canopyGlass(float3 n, float3 v, float3 toSun, float3 sunRad, float3 skyAmbient,
                                     float3 cabinAmbient, float shieldSun, float3 rbRefl, float3 rbGhost,
                                     float3 p, float fp, float dust, float scratches, float thickness) {
        float nv = max(dot(n, v), 0.02f);
        float F = ck_fresnelGlass(nv);
        // Inner surface mirrors the cabin; the outer surface returns a second, fainter copy, shifted by the
        // plate thickness (a real double image of the glare shield), after crossing the inner surface twice.
        float3 cab = ck_cabinRadiance(rbRefl, cabinAmbient, sunRad, shieldSun) * F;
        float3 ghost = ck_cabinRadiance(rbGhost, cabinAmbient, sunRad, shieldSun) * ((1.0 - F) * (1.0 - F) * F);
        float3 refl = cab + ghost;
        float T = (1.0 - F) / (1.0 + F);                                       // both surfaces, incoherent sum
        T *= 0.985;                                                            // slight absorption of the (green) plate
        // Sun scattered by the dust film and the scratch edges. The film lies on both faces; at glancing
        // incidence the sun crosses more of it (1/cos), so a low sun on a banking turn flares the screen.
        float cosEye = dot(-v, toSun);                                         // 1 when looking into the sun
        float ns = abs(dot(n, toSun));
        float graze = min(1.0 / max(ns, 0.18f), 4.0f);
        float film = ck_dustFilm(p, fp, dust);
        float sc = scratches * saturate(max(ck_scratchLayer(p.yz, 0.35, fp, 0.0), ck_scratchLayer(p.yz, 0.9, fp, 41.0))
                                        + 0.6 * ck_wiperArcs(p.yz, float2(0.0, -0.40), fp));
        float3 dustLit = sunRad * ck_hg(cosEye, 0.62) * 1.9 * graze + skyAmbient * 0.045;
        float3 scrLit = sunRad * ck_hg(cosEye, 0.85) * 3.2 * graze + skyAmbient * 0.03;
        float3 scat = dustLit * film + scrLit * sc;
        // Particles and scratches also block a little of what is behind.
        float block = saturate(film * 0.25 + sc * 0.12);
        CKGlassOut o;
        o.rgb = refl + scat * T;
        o.alpha = saturate(1.0 - T * (1.0 - block));
        return o;
    }

    // ---- Contact shadows and AO (screen space, shared with the cockpit contact pass) ----------------------

    /// Interleaved gradient noise (Jimenez 2014) for the step jitter.
    static float ck_ign(float2 px) { return fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715)))); }

    // ===================================================================================================
    // Part 2: glue into the world pass (append after WorldShaders.source)
    // ===================================================================================================

    static float3 ck_bodyToWorld(constant WorldUniforms& u, float3 b) {
        return u.model[0].xyz * b.x + u.model[1].xyz * b.y + u.model[2].xyz * b.z;
    }

    /// Cockpit `m == 12` (polished metal) in the cabin pass (`u.quality.y > 0`): bezel rings are spun (circular
    /// brushing), tubes are brushed along their axis, flat plates along the body's y axis. `dpx…dny` are the
    /// screen derivatives of `in.rel` and of the *unflipped* unit normal, taken by the caller in uniform
    /// control flow.
    static float3 ck_cockpitMetal(constant WorldUniforms& u, WorldVarying in, float3 n, float3 dir, float3 albedo,
                                  float3 ambient, float vis, float cloudShade, float3 toSun, float fp,
                                  float3 dpx, float3 dpy, float3 dnx, float3 dny) {
        float3 v = -dir;
        // Tangent candidates.
        float onRing;
        float3 tRing = ck_bodyToWorld(u, ck_ringTangentBody(in.local, onRing));
        float conf;
        float3 flatT = ck_bodyToWorld(u, float3(0.0, 1.0, 0.0));
        float3 tTube = ck_axisFromCurvature(n, dpx, dpy, dnx, dny, flatT, conf);
        float3 t = ck_ortho(n, flatT, ck_bodyToWorld(u, float3(0.0, 0.0, 1.0)));
        if (dot(t, tTube) < 0.0) tTube = -tTube;                 // eigenvector sign is arbitrary; mix(t, -t) would be 0
        t = ck_ortho(n, mix(t, tTube, conf), t);
        bool ring = onRing > 0.5 && abs(dot(n, ck_bodyToWorld(u, float3(-cos(CK_PANEL_TILT), 0.0, -sin(CK_PANEL_TILT))))) > 0.9;
        if (ring) t = ck_ortho(n, tRing, t);
        // Grooves, in object space so the pattern does not swim with the camera: circular on rings (across =
        // radius, along = angle × a reference radius), otherwise across/along the tangent.
        float2 gc;
        float gd = ck_nearestGauge(in.local.yz, gc);
        float2 rv = in.local.yz - gc;
        float3 tB = float3(dot(t, u.model[0].xyz), dot(t, u.model[1].xyz), dot(t, u.model[2].xyz));
        float3 nB = float3(dot(n, u.model[0].xyz), dot(n, u.model[1].xyz), dot(n, u.model[2].xyz));
        float across = ring ? gd : dot(in.local, cross(nB, tB));
        float along = ring ? atan2(rv.y, rv.x) * 0.045 : dot(in.local, tB);
        float streak = ck_brush(across, along, fp);
        float rough = clamp(0.30 + 0.10 * streak, 0.12, 0.6);
        float aniso = ring ? 0.80 : 0.65;
        float3 f0 = clamp(albedo * (0.94 + 0.06 * streak), 0.0f, 0.95f);          // polished: albedo is the reflectance
        float3 env = skyEnv(u, ck_bentReflect(n, t, v, aniso));
        // Cabin fill from the cabin pass, plus the sky and ground through the windows: metal reflects the
        // cabin too, so keep a floor so it never goes black in shade.
        // `vis` from the cabin pass is nonzero only on the glare shield (x > 1.1 m), so it would kill every sun
        // highlight on the panel metal. The sun reaches the cabin through the windows: use the sun elevation and
        // the cloud shade instead (the airframe's own shadow is not modelled for the cabin).
        float winSun = saturate(toSun.z * 3.0) * (1.0 - cloudShade);
        float occ = mix(0.45, 1.0, saturate(winSun * 0.5 + 0.5));
        float3 sun = u.sunColour.rgb * winSun;
        float3 metalCol = ck_brushedMetal(n, t, v, toSun, f0, rough, aniso, sun, env * 0.6 + ambient * 0.5, ambient, occ);
        // Dark `.metal` parts (the black throttle knob, switch caps) are anodised or moulded, not bare metal:
        // they take the dielectric lobe, so they are not mirrors that go black.
        float lum = dot(albedo, float3(0.2126, 0.7152, 0.0722));
        float metalness = smoothstep(0.08, 0.30, lum);
        float3 plastic = pbrDielectric(albedo, n, v, toSun, 0.42, u.sunColour.rgb, skyEnv(u, reflect(dir, n)) * 0.6, winSun) + albedo * ambient;
        return mix(plastic, metalCol, metalness);
    }

    /// Pipeline pair for the canopy glass: `world_vertex` + this fragment, over the aircraft vertex buffer,
    /// drawn with `u.cameraPos.w = 0` so the inner faces of the glazing survive (the main pass discards them
    /// in the cockpit view). Blend: source one, destination oneMinusSourceAlpha; depth test greater, no write.
    /// buffer(2): x = dust 0…1, y = scratches 0…1, z = plate thickness (m), w unused.
    fragment float4 canopy_glass_fragment(WorldVarying in [[stage_in]], constant WorldUniforms& u [[buffer(1)]],
                                          constant float4& gp [[buffer(2)]],
                                          depth2d_array<float> sm [[texture(2)]]) {
        float fp = length(fwidth(in.local));                  // derivatives before any discard (uniform flow)
        if (in.material != 10.0) discard_fragment();
        float dist = length(in.rel);
        float3 dir = in.rel / max(dist, 1e-3);
        float3 n = normalize(in.normal);
        if (dot(n, dir) <= 0.0) discard_fragment();            // outer faces are the main pass's
        Skin sk = fuselageSkin(in.local, fp);
        if (sk.glass < 0.01) discard_fragment();
        n = -n;                                                // face the eye, the glass seen from inside
        float3 v = -dir;
        float3 toSun = u.sunDir.xyz;
        // Sun on the glass from outside: the airframe's roof and the cascades decide.
        float vis = toSun.z > -0.05 ? shadowVisibility(u, sm, in.rel, -n, dist, max(0.0f, dot(-n, toSun))) : 0.0;
        float3 sunRad = u.sunColour.rgb * vis;
        float3 ambient = (u.ambientSky.rgb * 0.75 + u.ambientGround.rgb * 0.9 + u.sunColour.rgb * 0.035) * max(u.quality.y, 1.0f);
        float3 r1 = reflect(dir, n);                           // cabin side
        // Ghost: the same reflection leaves the second surface one plate thickness (×2) further along the glass.
        float nv = max(dot(n, v), 0.05f);
        float shift = 2.0 * ck_plateShift(nv, gp.z);
        float3 tang = normalize(dir - n * dot(dir, n) + float3(1e-6, 0.0, 0.0));
        float3 r2 = normalize(r1 + tang * (shift / 0.9));      // 0.9 m ≈ distance to the glare shield
        float3 rb1 = float3(dot(r1, u.model[0].xyz), dot(r1, u.model[1].xyz), dot(r1, u.model[2].xyz));
        float3 rb2 = float3(dot(r2, u.model[0].xyz), dot(r2, u.model[1].xyz), dot(r2, u.model[2].xyz));
        // Glare shield in the sun through the windscreen (same test as the cabin fill).
        float shieldSun = vis * saturate(toSun.z * 3.0);
        CKGlassOut g = ck_canopyGlass(n, v, toSun, sunRad, u.ambientSky.rgb, ambient, shieldSun, rb1, rb2,
                                      in.local, fp, gp.x, gp.y, gp.z);
        return float4(g.rgb * u.sunColour.w * sk.glass, g.alpha * sk.glass);
    }
    """
}
