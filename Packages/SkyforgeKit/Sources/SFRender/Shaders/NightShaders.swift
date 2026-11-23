// SKYFORGE — Apache-2.0
// Night pass MSL: star points, additive night sky (moon with phase, Milky Way, airglow, twilight tint) and
// light sprites / aircraft cone lights. Drawn additively over the Hillaire LUT sky. See docs/rounds/ROUND5_night.md.
// Swift mirrors: NightSkyUniforms, NightLight.packed(), ConeLight in SFRender.

public enum NightShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct NTUniforms {
        float4 camRight;     // xyz, unused
        float4 camUp;
        float4 camFwd;
        float4 view;         // tanHalfFovX, tanHalfFovY, pixelAngle (rad), time (s)
        float4 moonDir;      // xyz ENU unit, angular radius (rad)
        float4 moonParams;   // illuminated fraction, brightness, earthshine, surface detail 0/1
        float4 sunDir;       // xyz ENU unit, unused
        float4 sky;          // limiting magnitude, darkness 0..1, airglow gain, milky way gain
        float4 galPole;      // xyz ENU
        float4 galCentre;    // xyz ENU
        float4 eqE;          // equatorial->ENU rows
        float4 eqN;
        float4 eqU;
        float4 twWarm;       // rgb warm horizon, saturation
        float4 twCool;       // rgb anti-solar tint, exposure boost
        float4 sprite;       // min sprite px, max distance (m), focal px, unused
    };

    struct NTFull { float4 position [[position]]; float2 uv; };

    vertex NTFull nt_full_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        NTFull o;
        o.position = float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
        o.uv = float2(p.x * 2.0f - 1.0f, p.y * 2.0f - 1.0f);
        return o;
    }

    static float3 nt_ray(constant NTUniforms& u, float2 ndc) {
        float3 r = u.camFwd.xyz + ndc.x * u.view.x * u.camRight.xyz + ndc.y * u.view.y * u.camUp.xyz;
        return normalize(r);
    }
    static float nt_hash(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031f);
        p3 += dot(p3, p3.yzx + 33.33f);
        return fract((p3.x + p3.y) * p3.z);
    }
    static float nt_vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0f - 2.0f * f);
        return mix(mix(nt_hash(i), nt_hash(i + float2(1, 0)), f.x), mix(nt_hash(i + float2(0, 1)), nt_hash(i + float2(1, 1)), f.x), f.y);
    }
    static float nt_fbm(float2 p) {
        float a = 0.5f, s = 0.0f;
        for (int i = 0; i < 4; i++) { s += a * nt_vnoise(p); p = p * 2.03f + 7.1f; a *= 0.5f; }
        return s;
    }

    // ---- stars -------------------------------------------------------------------------------------
    struct NTStarOut { float4 position [[position]]; float4 color; float size [[point_size]]; };

    vertex NTStarOut nt_star_vertex(uint vid [[vertex_id]], constant float4* stars [[buffer(0)]],
                                    constant NTUniforms& u [[buffer(1)]]) {
        float4 a = stars[vid * 2], b = stars[vid * 2 + 1];
        float3 e = float3(dot(u.eqE.xyz, a.xyz), dot(u.eqN.xyz, a.xyz), dot(u.eqU.xyz, a.xyz));
        float x = dot(e, u.camRight.xyz), y = dot(e, u.camUp.xyz), z = dot(e, u.camFwd.xyz);
        NTStarOut o;
        // stars sit at infinity: reversed-Z depth 0. Drawn before terrain with depth test off (terrain overwrites them);
        // if drawn after terrain, use depth compare .greaterEqual (never writes) so any geometry occludes them.
        o.position = float4(x / u.view.x, y / u.view.y, 0.0f, z);
        float vis = 1.0f - smoothstep(u.sky.x - 0.4f, u.sky.x + 0.6f, a.w);       // fades in with twilight, per magnitude
        float horizon = smoothstep(-0.02f, 0.06f, e.z);                      // below horizon: terrain hides them
        float flux = pow(10.0f, -0.4f * (a.w - 1.0f));                       // mag 1 = reference
        float px = clamp(1.4f + 0.9f * log2(max(flux, 1.0e-3f) + 1.0f), 1.5f, 6.0f);
        float comp = min(1.0f, flux * 2.0f / (px * px));                     // energy conserving: bigger dot, same light
        // scintillation-free: constant brightness, fixed minimum footprint
        o.color = float4(b.rgb * clamp(comp * 6.0f, 0.04f, 1.0f), vis * horizon * u.sky.y);
        o.size = px;
        return o;
    }
    fragment float4 nt_star_fragment(NTStarOut in [[stage_in]], float2 pc [[point_coord]]) {
        float2 d = pc * 2.0f - 1.0f;
        float g = exp(-dot(d, d) * 3.2f);
        return float4(in.color.rgb * g * in.color.a, g * in.color.a);
    }

    // ---- sky: moon, milky way, airglow, twilight ------------------------------------------------------
    static float3 nt_moon(constant NTUniforms& u, float3 ray) {
        float3 m = u.moonDir.xyz;
        float R = u.moonDir.w;
        float cosA = clamp(dot(ray, m), -1.0f, 1.0f);
        float ang = acos(cosA);
        float bright = u.moonParams.y;
        // halo (always on, scales with phase)
        float halo = bright * (0.012f * exp(-ang / (R * 6.0f)) + 0.0025f * exp(-ang / (R * 30.0f)));
        float3 col = float3(0.85f, 0.9f, 1.0f) * halo;
        if (ang < R * 1.6f) {
            float3 e1 = normalize(cross(m, float3(0, 0, 1)));
            if (abs(m.z) > 0.999f) e1 = float3(1, 0, 0);
            float3 e2 = cross(e1, m);
            float2 p = float2(dot(ray, e1), dot(ray, e2)) / (sin(R) * 1.0f);
            float r2 = dot(p, p);
            float edge = 1.0f - smoothstep(1.0f - u.view.z / max(R, 1e-5f), 1.0f + u.view.z / max(R, 1e-5f), sqrt(r2));
            float3 n = normalize(p.x * e1 + p.y * e2 - sqrt(max(0.0f, 1.0f - r2)) * m);
            float lit = smoothstep(-0.02f, 0.22f, dot(n, u.sunDir.xyz));         // retro-reflective: flat to terminator
            float maria = 1.0f;
            if (u.moonParams.w > 0.5f) maria = 0.62f + 0.38f * smoothstep(0.35f, 0.65f, nt_fbm(p * 2.6f + 3.0f));
            float limb = 0.8f + 0.2f * sqrt(max(0.0f, 1.0f - r2));
            float3 surf = float3(1.0f, 0.97f, 0.9f) * maria * limb;
            float3 disc = surf * (lit * bright * 40.0f + u.moonParams.z * 0.6f);   // earthshine on the dark side
            col = mix(col, col + disc, edge);
        }
        return col;
    }

    static float3 nt_milkyway(constant NTUniforms& u, float3 ray) {
        float sinB = dot(ray, u.galPole.xyz);
        float b = asin(clamp(sinB, -1.0f, 1.0f)) * 57.29578f;
        float band = exp(-(b * b) / 140.0f);
        float c = max(0.0f, dot(ray, u.galCentre.xyz));
        float3 axis = normalize(cross(u.galPole.xyz, u.galCentre.xyz));
        float2 q = float2(atan2(dot(ray, axis), dot(ray, u.galCentre.xyz)) * 3.0f, b * 0.18f);
        float dust = smoothstep(0.25f, 0.85f, nt_fbm(q * 2.2f));
        float glow = band * (0.5f + 0.9f * c * c) * (1.0f - 0.55f * dust * (1.0f - smoothstep(0.0f, 8.0f, abs(b))));
        return float3(0.55f, 0.6f, 0.75f) * glow * 0.006f * u.sky.w;
    }

    static float3 nt_airglow(constant NTUniforms& u, float3 ray) {
        float el = ray.z;
        float z = acos(clamp(el, 0.02f, 1.0f));
        float k = 6371.0f / 6461.0f;
        float vr = 1.0f / sqrt(max(0.05f, 1.0f - k * k * sin(z) * sin(z)));
        float below = smoothstep(-0.03f, 0.03f, el);
        // faint cellular banding so the airglow is not a flat wash
        float band = 0.85f + 0.3f * nt_fbm(ray.xy / max(0.25f, el + 0.3f) * 1.4f);
        // Gain 0.0002 (was 0.0025): the twilight exposure boost (up to 40x at night) multiplies this term, so the
        // old gain turned the whole night sky green (PR #112 frame). Airglow should be a faint tint only.
        return float3(0.10f, 0.55f, 0.22f) * vr * band * below * 0.0002f * u.sky.z;
    }

    fragment float4 nt_sky_fragment(NTFull in [[stage_in]], constant NTUniforms& u [[buffer(0)]]) {
        float3 ray = nt_ray(u, in.uv);
        float3 col = float3(0.0f);
        float dark = u.sky.y;
        // twilight: warm band toward the sun, belt of Venus opposite
        float sunAz = dot(normalize(float3(ray.xy, 1.0e-4f)), normalize(float3(u.sunDir.xy, 1.0e-4f)));
        float horizonBand = exp(-abs(ray.z) * 7.0f);
        float toSun = 0.5f + 0.5f * sunAz;
        col += u.twWarm.rgb * horizonBand * pow(toSun, 3.0f) * 0.35f;
        col += u.twCool.rgb * horizonBand * pow(1.0f - toSun, 2.0f) * 0.25f;
        if (dark > 0.001f) {
            col += nt_milkyway(u, ray) * dark;
            col += nt_airglow(u, ray) * dark;
        }
        col += nt_moon(u, ray) * smoothstep(-0.05f, 0.02f, ray.z + 0.04f);
        col = mix(float3(dot(col, float3(0.299f, 0.587f, 0.114f))), col, u.twWarm.w);
        return float4(col * u.twCool.w, 1.0f);
    }

    // ---- light sprites ---------------------------------------------------------------------------------
    struct NTLight {
        float4 posRadius;     // xyz metres (camera-relative), radius m
        float4 colorIntensity;
        float4 dirCosOuter;   // beam axis, cos(outer half angle)
        float4 extra;         // cos(inner), strobe flag, phase, kind
    };
    struct NTSpriteOut { float4 position [[position]]; float2 uv; float4 color; };

    vertex NTSpriteOut nt_light_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                       constant NTLight* lights [[buffer(0)]],
                                       constant NTUniforms& u [[buffer(1)]]) {
        constant NTLight& L = lights[iid];
        float2 corner = float2((vid & 1) ? 1.0f : -1.0f, (vid & 2) ? 1.0f : -1.0f);
        float3 rel = L.posRadius.xyz;
        float x = dot(rel, u.camRight.xyz), y = dot(rel, u.camUp.xyz), z = dot(rel, u.camFwd.xyz);
        NTSpriteOut o;
        o.uv = corner;
        o.color = float4(0.0f);
        if (z < 0.5f) { o.position = float4(2.0f, 2.0f, 2.0f, 1.0f); return o; }
        float dist = length(rel);
        // flicker-free sizing: min footprint in px, energy falls with area below it, smooth far fade
        float px = 2.0f * L.posRadius.w * u.sprite.z / dist;
        float size = min(max(px, u.sprite.x), 128.0f);   // same 128 px cap as LightSprite.metrics
        float comp = px >= u.sprite.x ? 1.0f : (px / u.sprite.x) * (px / u.sprite.x);
        float fade = clamp((u.sprite.y - dist) / max(0.25f * u.sprite.y, 1e-3f), 0.0f, 1.0f);
        fade = fade * fade * (3.0f - 2.0f * fade);
        // beam gain (smooth, no hard cone edge)
        float3 toCam = -rel / dist;
        float cs = dot(toCam, L.dirCosOuter.xyz);
        float gain = (L.dirCosOuter.w <= -0.999f) ? 1.0f : smoothstep(L.dirCosOuter.w, L.extra.x, cs);
        if (L.extra.x == 0.0f) gain = 1.0f;
        float strobe = 1.0f;
        if (L.extra.y > 0.5f) {
            float t = fmod(u.view.w + L.extra.z + 120.0f, 1.2f);
            strobe = ((t < 0.06f) || (t >= 0.20f && t < 0.26f)) ? 1.0f : 0.0f;
        }
        float halo = 3.0f;                                         // quad covers the glow tail
        float2 viewport2 = float2(u.sprite.z * u.view.x, u.sprite.z * u.view.y);   // half-extent in px
        float2 ndcOff = corner * (size * halo) / viewport2;
        // reversed infinite-Z depth = near / z (WorldRenderer.reversedZProjection); u.sprite.w = near plane (m).
        // The pass must depth-test (.greater, write off) against the scene depth so terrain occludes far lights.
        o.position = float4(float2(x / u.view.x, y / u.view.y) + ndcOff * z, u.sprite.w, z);
        o.color = float4(L.colorIntensity.rgb * L.colorIntensity.w * comp * fade * gain * strobe, 1.0f);
        return o;
    }
    fragment float4 nt_light_fragment(NTSpriteOut in [[stage_in]]) {
        float r2 = dot(in.uv, in.uv);
        if (r2 > 1.0f) return float4(0.0f);
        float core = exp(-r2 * 38.0f);                 // tight core
        float glow = exp(-r2 * 7.0f) * 0.22f;          // soft bloom sprite
        float tail = 0.02f / (1.0f + r2 * 40.0f);
        float edge = 1.0f - smoothstep(0.7f, 1.0f, sqrt(r2));  // no visible quad edge
        float3 c = in.color.rgb * (core + glow + tail) * edge;
        return float4(c, 0.0f);
    }

    // ---- aircraft landing / taxi light cone, call from the world fragment shader -----------------------
    struct NTCone {
        float4 posRange;        // xyz world, range
        float4 dirIntensity;    // xyz unit, intensity
        float4 angles;          // cos(inner), cos(outer), unused, unused
        float4 color;
    };
    static float3 nt_cone_light(constant NTCone& c, float3 worldPos, float3 normal) {
        float3 v = worldPos - c.posRange.xyz;
        float dist = max(1.0f, length(v));
        float3 l = v / dist;
        float t = clamp((dot(l, c.dirIntensity.xyz) - c.angles.y) / max(1.0e-4f, c.angles.x - c.angles.y), 0.0f, 1.0f);
        float cone = t * t * (3.0f - 2.0f * t);
        float r = dist / c.posRange.w;
        float fall = 1.0f / (1.0f + 4.0f * r * r) * max(0.0f, 1.0f - r * r);
        float ndl = max(0.0f, -dot(normal, l));
        return c.color.rgb * (c.dirIntensity.w * cone * fall * ndl / (dist * 0.02f + 1.0f));
    }
    """
}
