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
        float4 tableDims;         // nD, nAz, nEl, unused
    };

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

    static float3 acesW(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    fragment float4 world_fragment(WorldVarying in [[stage_in]], constant WorldUniforms& u [[buffer(1)]],
                                   texture3d<float> ins [[texture(0)]], texture3d<float> tr [[texture(1)]]) {
        float dist = length(in.rel);
        float3 dir = in.rel / max(dist, 1e-3);
        float3 n = normalize(in.normal);
        if (dot(n, dir) > 0.0) n = -n;                       // two-sided, robust to winding
        float3 toSun = u.sunDir.xyz;
        float ndl = dot(n, toSun);
        float3 ambient = mix(u.ambientGround.rgb, u.ambientSky.rgb, n.z * 0.5 + 0.5);
        float m = in.material;
        float3 col;
        if (m == 1.0) {                                      // water
            float3 r = reflect(dir, float3(0, 0, 1));
            float cosT = max(0.0, -dir.z);
            float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            float3 refl = u.skyHorizon.rgb + u.sunColour.rgb * pow(max(0.0, dot(r, toSun)), 600.0) * 30.0;
            float3 body = in.albedo * (ambient * 0.6 + u.sunColour.rgb * max(0.0, toSun.z) * 0.15);
            col = mix(body, refl, min(1.0, fres));
        } else if (m == 2.0) {                               // foliage: wrap + back-scatter
            float wrap = max(0.0, ndl * 0.55 + 0.45);
            float back = pow(max(0.0, dot(dir, toSun)), 4.0) * 0.35;
            col = in.albedo * (u.sunColour.rgb * (wrap + back) + ambient * 0.85);
        } else {
            col = in.albedo * (u.sunColour.rgb * max(0.0, ndl) + ambient);
            if (m == 6.0 || m == 3.0) {                      // paint, road: Blinn-Phong highlight
                float3 h = normalize(toSun - dir);
                float spec = pow(max(0.0, dot(n, h)), m == 6.0 ? 80.0 : 20.0) * (m == 6.0 ? 0.6 : 0.08);
                col += u.sunColour.rgb * spec;
            }
        }
        float3 L, T;
        aerial(u, ins, tr, dir, dist, L, T);
        col = col * T + L;
        float3 mapped = acesW(col * u.sunColour.w);
        return float4(pow(mapped, float3(1.0 / 2.2)), 1.0);
    }
    """
}
