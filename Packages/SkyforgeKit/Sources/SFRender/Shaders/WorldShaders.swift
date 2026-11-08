// SKYFORGE — Apache-2.0
// Forward world pass for Quick Flight: packed vertices (20 B), hemispheric ambient + sun,
// foliage wrap lighting, Fresnel water, and aerial perspective from the SFAtmosphere-derived
// 3D tables (same mapping as SFPreview.PhysicalSky.aerial). Reversed-Z depth.

public enum WorldShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct WorldVertex {
        packed_float3 position;   // relative to the mesh origin (m), z up
        char4 normal;             // snorm8 xyz
        uchar4 colour;            // sqrt-encoded linear albedo rgb, material id in a
    };

    struct WorldUniforms {
        float4x4 viewProj;
        float4x4 model;           // mesh → camera-relative world
        float4 sunDir;            // xyz to sun (z up), sun azimuth atan2(y, x)
        float4 sunColour;         // rgb, exposure
        float4 ambientSky;        // rgb, max aerial distance (km)
        float4 ambientGround;     // rgb, unused
        float4 skyHorizon;        // rgb (water reflection), unused
        float4 tableDims;         // nD, nAz, nEl, cascade count
        float4x4 shadow0;         // camera-relative world → cascade 0 clip (orthographic)
        float4x4 shadow1;
        float4 cascadeSplits;     // far edge (m) of cascade 0, 1; texel size (m) of cascade 0, 1
        float4 cascadeDepth;      // light-space depth range (m) of cascade 0, 1
        float4 cameraPos;         // camera world x, y modulo 4096 m (noise period), z, w = 1: discard back faces
        float4 cameraLocal;       // camera x, y, z in region metres (imagery lookup), unused
        float4 imageryNear;       // centre x, y, half extent, 1 if present
        float4 imageryFar;        // centre x, y, half extent, 1 if present
        CloudLayerGPU clouds;     // cumulus layer for cloud shadows (coverage 0 = none)
    };

    struct TerrainVertex { packed_float3 position; char4 normal; };
    struct TreeInstanceGPU { packed_float3 position; float height; packed_float3 colour; float kind; };

    struct ShadowUniforms { float4x4 lightViewProj; float4x4 model; };

    vertex float4 shadow_vertex(const device WorldVertex* v [[buffer(0)]], constant ShadowUniforms& u [[buffer(1)]],
                                uint vid [[vertex_id]]) {
        return u.lightViewProj * (u.model * float4(float3(v[vid].position), 1.0));
    }

    vertex float4 shadow_terrain_vertex(const device TerrainVertex* v [[buffer(0)]], constant ShadowUniforms& u [[buffer(1)]],
                                        uint vid [[vertex_id]]) {
        return u.lightViewProj * (u.model * float4(float3(v[vid].position), 1.0));
    }

    vertex float4 shadow_tree_vertex(const device TerrainVertex* v [[buffer(0)]], constant ShadowUniforms& u [[buffer(1)]],
                                     const device TreeInstanceGPU* inst [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        TreeInstanceGPU t = inst[iid];
        float3 p = float3(v[vid].position) * t.height + float3(t.position);
        return u.lightViewProj * (u.model * float4(p, 1.0));
    }

    struct WorldVarying {
        float4 position [[position]];
        float3 rel;               // camera-relative world position
        float3 normal;
        float3 albedo;
        float material;
    };

    vertex WorldVarying world_vertex(const device WorldVertex* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                     uint vid [[vertex_id]]) {
        WorldVertex w = v[vid];
        float4 p = u.model * float4(float3(w.position), 1.0);
        WorldVarying o;
        o.position = u.viewProj * p;
        o.rel = p.xyz;
        float3 n = float3(w.normal.xyz) / 127.0;
        o.normal = normalize((u.model * float4(n, 0.0)).xyz);
        float3 c = float3(w.colour.rgb) / 255.0;
        o.albedo = c * c;
        o.material = float(w.colour.a);
        return o;
    }

    vertex WorldVarying terrain_vertex(const device TerrainVertex* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                       uint vid [[vertex_id]]) {
        TerrainVertex w = v[vid];
        float4 p = u.model * float4(float3(w.position), 1.0);
        WorldVarying o;
        o.position = u.viewProj * p;
        o.rel = p.xyz;
        o.normal = normalize(float3(w.normal.xyz) / 127.0);
        o.albedo = float3(0.15, 0.17, 0.12);
        o.material = 8.0;                       // real terrain: albedo from imagery in the fragment shader
        return o;
    }

    vertex WorldVarying tree_vertex(const device TerrainVertex* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                    const device TreeInstanceGPU* inst [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        TreeInstanceGPU t = inst[iid];
        TerrainVertex w = v[vid];
        float3 local = float3(w.position);
        float4 p = u.model * float4(local * t.height + float3(t.position), 1.0);
        WorldVarying o;
        o.position = u.viewProj * p;
        o.rel = p.xyz;
        o.normal = normalize(float3(w.normal.xyz) / 127.0);
        // Trunk vertices (marked by a negative normal w) are bark-coloured.
        o.albedo = w.normal.w < 0 ? float3(0.06, 0.045, 0.03) : float3(t.colour) * (0.85 + 0.3 * saturate(local.z));
        o.material = w.normal.w < 0 ? 0.0 : 2.0;
        return o;
    }

    constexpr sampler imgSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, coord::normalized);

    constexpr sampler tbl(filter::linear, address::clamp_to_edge, coord::normalized);

    static void aerial(constant WorldUniforms& u, texture3d<float> ins, texture3d<float> tr, float3 dir, float dist,
                       thread float3& L, thread float3& T) {
        const float PI = 3.14159265358979;
        float nD = u.tableDims.x, nAz = u.tableDims.y, nEl = u.tableDims.z;
        float el = asin(clamp(dir.z, -1.0f, 1.0f));
        float s = sqrt(abs(el) / (PI / 2.0)) * (el < 0.0 ? -1.0 : 1.0);
        float fj = clamp((s + 1.0) * 0.5, 0.0, 1.0) * (nEl - 1.0);
        float rel = atan2(dir.y, dir.x) - u.sunDir.w;
        rel = abs(rel - 2.0 * PI * floor(rel / (2.0 * PI) + 0.5));
        float fi = min(nAz - 1.0, rel / PI * (nAz - 1.0));
        float w = min(1.0, sqrt(dist / 1000.0 / u.ambientSky.w));
        float fk = w * nD - 1.0;
        float3 uvw = float3((max(fk, 0.0) + 0.5) / nD, (fi + 0.5) / nAz, (fj + 0.5) / nEl);
        L = ins.sample(tbl, uvw).rgb;
        T = tr.sample(tbl, uvw).rgb;
        if (fk < 0.0) { float f = fk + 1.0; L *= f; T = 1.0 + (T - 1.0) * f; }
    }

    constexpr sampler shadowCmp(filter::linear, address::clamp_to_edge, compare_func::less_equal);

    /// 3×3 PCF with hardware comparison, cascade chosen by distance; 1 = lit.
    static float shadowVisibility(constant WorldUniforms& u, depth2d_array<float> sm, float3 rel, float3 n, float dist, float ndl) {
        if (u.tableDims.w < 1.0) return 1.0;
        int c = dist < u.cascadeSplits.x ? 0 : (dist < u.cascadeSplits.y ? 1 : -1);
        if (c < 0) return 1.0;
        float texel = c == 0 ? u.cascadeSplits.z : u.cascadeSplits.w;
        // Normal offset + slope-scaled bias (as the CPU preview).
        float tanT = sqrt(max(0.0, 1.0 - ndl * ndl)) / max(ndl, 0.05);
        float3 p = rel + n * texel * 1.5;
        float4 lp = (c == 0 ? u.shadow0 : u.shadow1) * float4(p, 1.0);
        float2 uv = lp.xy * float2(0.5, -0.5) + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) return 1.0;
        float bias = texel * (0.5 + min(6.0, tanT)) / (c == 0 ? u.cascadeDepth.x : u.cascadeDepth.y);
        float z = lp.z - bias;
        float2 ts = 1.0 / float2(sm.get_width(), sm.get_height());
        float lit = 0.0;
        for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++)
            lit += sm.sample_compare(shadowCmp, uv + float2(x, y) * ts, uint(c), z);
        return lit / 9.0;
    }

    // Value noise on a lattice that repeats every `period` cells, so world coordinates taken
    // modulo 4096 m stay seamless (cell sizes 2, 8 and 32 m divide 4096).
    static float hashP(float2 i, float period) {
        i = fmod(fmod(i, period) + period, period);
        float2 p = fract(i * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return fract((p.x + p.y) * p.x);
    }
    static float vnoiseP(float2 x, float period) {
        float2 i = floor(x), f = fract(x);
        float2 u = f * f * (3.0 - 2.0 * f);
        float a = hashP(i, period), b = hashP(i + float2(1, 0), period);
        float c = hashP(i + float2(0, 1), period), d = hashP(i + float2(1, 1), period);
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 2.0 - 1.0;
    }
    static float groundNoise(float2 w, float cell) { return vnoiseP(w / cell, 4096.0 / cell); }

    /// Cook–Torrance GGX for dielectric paint and glass (F0 = 0.04), with a sky-tinted
    /// environment term so the airframe never looks like flat plastic.
    static float3 pbrDielectric(float3 albedo, float3 n, float3 v, float3 l, float rough, float3 sun, float3 env, float vis) {
        float3 h = normalize(l + v);
        float nl = max(0.0, dot(n, l)), nv = max(1e-4, dot(n, v)), nh = max(0.0, dot(n, h)), vh = max(0.0, dot(v, h));
        float a = rough * rough, a2 = a * a;
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float D = a2 / (3.14159265 * dd * dd);
        float k = (rough + 1.0) * (rough + 1.0) / 8.0;
        float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
        float F = 0.04 + 0.96 * pow(1.0 - vh, 5.0);
        float spec = D * G * F / max(1e-4, 4.0 * nl * nv);
        float Fv = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
        return albedo * (1.0 - F) * sun * nl * vis + sun * spec * nl * vis + env * Fv * (1.0 - rough * 0.7);
    }

    static float3 acesW(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    fragment float4 world_fragment(WorldVarying in [[stage_in]], constant WorldUniforms& u [[buffer(1)]],
                                   texture3d<float> ins [[texture(0)]], texture3d<float> tr [[texture(1)]],
                                   depth2d_array<float> sm [[texture(2)]],
                                   texture2d<float> imgNear [[texture(3)]], texture2d<float> imgFar [[texture(4)]],
                                   texture2d<float> waterMask [[texture(5)]]) {
        float dist = length(in.rel);
        float3 dir = in.rel / max(dist, 1e-3);
        float3 n = normalize(in.normal);
        // Cockpit view: the camera is inside the airframe, so its inner (back) faces are skipped and
        // the cabin opens onto the world; the cowling, wings and struts still render from outside.
        if (u.cameraPos.w > 0.5 && dot(n, dir) > 0.0) discard_fragment();
        if (dot(n, dir) > 0.0) n = -n;                       // two-sided, robust to winding
        float3 toSun = u.sunDir.xyz;
        float3 albedo = in.albedo;
        float m = in.material;
        bool imageryWater = false;
        if (m == 8.0) {
            float2 w = in.rel.xy + u.cameraLocal.xy;
            float2 nuv = (w - (u.imageryNear.xy - u.imageryNear.z)) / (2.0 * u.imageryNear.z);
            nuv.y = 1.0 - nuv.y;                                   // row 0 = north edge
            float2 fuv = (w - (u.imageryFar.xy - u.imageryFar.z)) / (2.0 * u.imageryFar.z);
            fuv.y = 1.0 - fuv.y;
            bool inNear = u.imageryNear.w > 0.5 && all(nuv > 0.002) && all(nuv < 0.998);
            float3 c = inNear ? imgNear.sample(imgSampler, nuv).rgb
                              : (u.imageryFar.w > 0.5 ? imgFar.sample(imgSampler, fuv).rgb : float3(0.12, 0.14, 0.10));
            // Same photo→albedo conversion as SFPreview.ImageryGround (textures are sRGB, so c is linear).
            albedo = pow(max(c, 0.0), 1.12) * 0.72;
            float wm = inNear ? waterMask.sample(imgSampler, nuv).r : 0.0;
            if (saturate((wm - 0.35) / 0.25) > 0.5) { imageryWater = true; albedo *= 0.7; }
            m = imageryWater ? 1.0 : 7.0;
        }
        if (m == 7.0 && dist < (in.material == 8.0 ? 350.0 : 1400.0)) {
            // Per-pixel ground detail (as SFPreview). Each octave fades out once its cell shrinks
            // below about two pixels (screen-space footprint from fwidth), so it never aliases.
            float2 w = in.rel.xy + u.cameraPos.xy;
            float fp = length(fwidth(w));
            float wFine = saturate(1.0 - fp / 1.0), wMid = saturate(1.0 - fp / 4.0), wDry = saturate(1.0 - fp / 16.0);
            float fade = 1.0 - dist / 1400.0;
            float fine = groundNoise(w, 2.0), mid = groundNoise(w + 17.0, 8.0), dry = groundNoise(w - 31.0, 32.0);
            albedo *= 1.0 + (fine * 0.08 * wFine + mid * 0.06 * wMid) * fade;
            albedo *= 1.0 + (float3(1.10, 1.02, 0.80) - 1.0) * (max(0.0, dry) * 0.45 * wDry * fade);
            float e = 0.6;
            float gx = groundNoise(w + float2(e, 0), 2.0) - groundNoise(w - float2(e, 0), 2.0);
            float gy = groundNoise(w + float2(0, e), 2.0) - groundNoise(w - float2(0, e), 2.0);
            n = normalize(n + float3(-gx, -gy, 0.0) * (0.12 * wFine * fade));
        }
        float ndl = dot(n, toSun);
        float vis = toSun.z > -0.05 ? shadowVisibility(u, sm, in.rel, n, dist, max(0.0f, ndl)) : 0.0;
        if (u.clouds.shape.z > 0.0 && toSun.z > 0.05 && vis > 0.0) {
            // Cloud shadow: optical depth along the sun ray through the cumulus slab (3 samples).
            float3 wp = in.rel + u.cameraLocal.xyz;
            float thick = u.clouds.shape.y, od = 0.0;
            for (int k = 0; k < 3; k++) {
                float z = u.clouds.shape.x + thick * (0.2 + 0.25 * float(k));
                float t = (z - wp.z) / toSun.z;
                if (t > 0.0) od += cl_density(wp + toSun * t, u.clouds);
            }
            od *= thick / 3.0 / toSun.z;
            vis *= max(0.12, exp(-0.35 * od));     // multiple scattering keeps cloud shadows soft, never black
        }
        float3 ambient = mix(u.ambientGround.rgb, u.ambientSky.rgb, n.z * 0.5 + 0.5);
        float3 col;
        if (m == 1.0) {                                      // water
            float3 r = reflect(dir, float3(0, 0, 1));
            float cosT = max(0.0, -dir.z);
            float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            float3 refl = u.skyHorizon.rgb + u.sunColour.rgb * pow(max(0.0, dot(r, toSun)), 600.0) * 30.0 * vis;
            float3 body = albedo * (ambient * 0.6 + u.sunColour.rgb * max(0.0, toSun.z) * 0.15);
            float reflScale = imageryWater ? 0.5 : 1.0;          // wind-roughened open water
            col = mix(body, refl * reflScale, min(1.0, fres * (imageryWater ? 0.8 : 1.0)));
        } else if (m == 2.0) {                               // foliage: wrap + back-scatter
            float wrap = max(0.0, ndl * 0.55 + 0.45);
            float back = pow(max(0.0, dot(dir, toSun)), 4.0) * 0.35;
            col = albedo * (u.sunColour.rgb * (wrap + back) * vis + ambient * 0.85);
        } else if (m == 6.0 || m == 5.0) {                   // aircraft paint / glass: GGX
            float rough = m == 6.0 ? 0.32 : 0.06;
            float3 env = mix(u.ambientGround.rgb, u.skyHorizon.rgb, saturate(reflect(dir, n).z * 0.5 + 0.5));
            col = pbrDielectric(albedo, n, -dir, toSun, rough, u.sunColour.rgb, env, vis) + albedo * ambient * (m == 6.0 ? 1.0 : 0.3);
        } else {
            col = albedo * (u.sunColour.rgb * max(0.0, ndl) * vis + ambient);
            if (m == 3.0) {                      // road: Blinn-Phong highlight
                float3 h = normalize(toSun - dir);
                float spec = pow(max(0.0, dot(n, h)), 20.0) * 0.08;
                col += u.sunColour.rgb * spec * vis;
            }
        }
        float3 L, T;
        aerial(u, ins, tr, dir, dist, L, T);
        col = col * T + L;
        float3 mapped = acesW(col * u.sunColour.w);
        return float4(pow(mapped, float3(1.0 / 2.2)), 1.0);
    }

    // Cockpit display (SF-1000 PFD): display-referred texture on a quad in aircraft body axes.
    struct ScreenVertex { packed_float3 position; packed_float2 uv; };
    struct ScreenVarying { float4 position [[position]]; float2 uv; float3 rel; };

    vertex ScreenVarying screen_vertex(const device ScreenVertex* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                       uint vid [[vertex_id]]) {
        ScreenVertex sv = v[vid];
        float4 p = u.model * float4(float3(sv.position), 1.0);
        ScreenVarying o;
        o.position = u.viewProj * p;
        o.uv = float2(sv.uv);
        o.rel = p.xyz;
        return o;
    }

    constexpr sampler screenSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, coord::normalized);

    fragment float4 screen_fragment(ScreenVarying in [[stage_in]], constant WorldUniforms& u [[buffer(1)]],
                                    texture2d<float> screen [[texture(0)]]) {
        float3 c = screen.sample(screenSampler, in.uv).rgb;    // gamma-encoded display pixels
        // Sun glare on the glass: a faint lift when the sun is in front of the panel.
        float glare = pow(saturate(dot(normalize(in.rel), u.sunDir.xyz) * -1.0), 8.0) * 0.06;
        return float4(c * 0.93 + glare, 1.0);
    }
    """
}
