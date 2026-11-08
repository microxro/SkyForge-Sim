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
        char4 normal;             // snorm8 xyz, w = field weight (−127…127; < 0 suburb impostor)
        uchar4 colour;            // sqrt-encoded linear albedo rgb, material id in a
    };

    struct WorldUniforms {
        float4x4 viewProj;
        float4x4 model;           // mesh → camera-relative world
        float4 sunDir;            // xyz to sun (z up), sun azimuth atan2(y, x)
        float4 sunColour;         // rgb, exposure
        float4 ambientSky;        // rgb, max aerial distance (km)
        float4 ambientGround;     // rgb, field pattern seed (24-bit integer as float)
        float4 skyHorizon;        // rgb (water reflection), field pattern: 0 none, 1 summer, 2 autumn
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
        float4 fieldGrid;         // farmed-parcel texture origin iu0, iv0 and size (width 0 = none)
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
        float field;              // FieldPattern weight (terrain mesh only)
        float3 local;             // mesh-local position (aircraft: body axes)
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
        o.field = float(w.normal.w) / 127.0;      // > 0 field parcels, < 0 suburb impostor
        o.local = float3(w.position);
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
        o.field = 0.0;
        o.local = float3(0.0);
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
        o.field = 0.0;
        o.local = float3(0.0);
        return o;
    }

    constexpr sampler imgSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, coord::normalized, max_anisotropy(8));

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
        float bias = texel * (0.8 + min(16.0, tanT * 1.4)) / (c == 0 ? u.cascadeDepth.x : u.cascadeDepth.y);   // low-sun acne (art review)
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

    // Field parcels and hedgerows: operation-for-operation mirror of SFPreview.FieldPattern.
    static uint fp_hash(int x, int y, uint s) {
        uint h = as_type<uint>(x) * 0x8DA6B343u;
        h ^= as_type<uint>(y) * 0xD8163841u;
        h ^= s * 0xCB1AB31Fu;
        h ^= h >> 13;
        h = h * 0x5BD1E995u;
        h ^= h >> 15;
        return h;
    }
    static float fp_unit(uint h) { return float(h & 0x00FFFFFFu) / 16777216.0; }
    static float fp_noise(float x, float y, uint s) {
        float fx = floor(x), fy = floor(y);
        int ix = int(fx), iy = int(fy);
        float tx = x - fx, ty = y - fy;
        tx = tx * tx * (3.0 - 2.0 * tx); ty = ty * ty * (3.0 - 2.0 * ty);
        float a = fp_unit(fp_hash(ix, iy, s)), b = fp_unit(fp_hash(ix + 1, iy, s));
        float c = fp_unit(fp_hash(ix, iy + 1, s)), d = fp_unit(fp_hash(ix + 1, iy + 1, s));
        float v = (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
        return v * 2.0 - 1.0;
    }
    constant float3 fpSummer[7] = { float3(0.74, 0.90, 0.80), float3(1.22, 1.10, 1.28), float3(1.98, 1.41, 1.84),
        float3(0.95, 0.60, 1.10), float3(1.70, 1.28, 2.05), float3(0.55, 0.70, 0.66), float3(1.32, 0.96, 1.30) };
    constant float3 fpAutumn[6] = { float3(1.43, 1.03, 1.57), float3(0.78, 0.54, 1.00), float3(0.60, 0.68, 0.82),
        float3(1.22, 0.89, 1.38), float3(0.76, 0.77, 0.95), float3(1.67, 1.21, 2.00) };
    static float fieldCoverage(float x, float y, float weight, uint seed, float band, float4 grid, texture2d<float> parcels) {
        float c = cos(0.35f), s = sin(0.35f);
        float wu = fp_noise(x / 420.0 + 7.3, y / 420.0, seed ^ 0x51u) * 22.0;
        float wv = fp_noise(x / 420.0, y / 420.0 - 9.1, seed ^ 0xA3u) * 22.0;
        float u = c * x + s * y + wu, v = -s * x + c * y + wv;
        float iu = floor(u / 110.0), iv = floor(v / 170.0);
        float t = 0.3 + 0.4 * fp_unit(fp_hash(int(iu), int(iv), seed ^ 0x5EEDu));
        if (grid.z > 0.0) {                                   // farmed parcels decided per parcel on the CPU
            float gx = iu - grid.x, gy = iv - grid.y;
            if (gx < 0.0 || gy < 0.0 || gx >= grid.z || gy >= grid.w) return 0.0;
            if (parcels.read(uint2(uint(gx), uint(gy))).r < 0.5) return 0.0;
            t = 0.5;                                          // weight is the local clip only
        }
        float k = min(1.0, max(0.0, (weight - (t - band * 0.5)) / band));
        return k * k * (3.0 - 2.0 * k);
    }
    static float2 fieldRowTilt(float x, float y, float footprint, uint seed, bool autumn) {
        float c = cos(0.35f), s = sin(0.35f);
        float wu = fp_noise(x / 420.0 + 7.3, y / 420.0, seed ^ 0x51u) * 22.0;
        float wv = fp_noise(x / 420.0, y / 420.0 - 9.1, seed ^ 0xA3u) * 22.0;
        float u = c * x + s * y + wu, v = -s * x + c * y + wv;
        uint h = fp_hash(int(floor(u / 110.0)), int(floor(v / 170.0)), seed);
        uint idx = autumn ? h % 6u : h % 7u;
        bool pasture = !autumn && (idx == 0u || idx == 5u);
        bool ploughed = autumn ? idx == 1u : idx == 3u;
        float spacing = pasture ? 14.0 : 3.0 + 3.0 * fp_unit(h >> 8);
        bool alongU = ((h >> 24) & 1u) == 0u;
        float coord = alongU ? u : v;
        float fade = min(1.0, max(0.0, 1.0 - max(0.05, footprint) * 4.0 / spacing));
        float strength = pasture ? 0.03 : (ploughed ? 0.20 : 0.10);
        float slope = cos(coord / spacing * 6.2831853) * strength * fade;
        float2 axis = alongU ? float2(c, s) : float2(-s, c);
        return -axis * slope;
    }
    static float3 fieldFactor(float x, float y, float footprint, uint seed, bool autumn) {
        const float PU = 110.0, PV = 170.0, HW = 1.2;
        float c = cos(0.35f), s = sin(0.35f);
        float wu = fp_noise(x / 420.0 + 7.3, y / 420.0, seed ^ 0x51u) * 22.0;
        float wv = fp_noise(x / 420.0, y / 420.0 - 9.1, seed ^ 0xA3u) * 22.0;
        float u = c * x + s * y + wu, v = -s * x + c * y + wv;
        float fu = u / PU, fv = v / PV;
        float iu = floor(fu), iv = floor(fv);
        uint h = fp_hash(int(iu), int(iv), seed);
        float3 col = autumn ? fpAutumn[h % 6u] : fpSummer[h % 7u];
        float tu = fu - iu, tv = fv - iv;
        float along = ((h >> 24) & 1u) == 0u ? tu : tv;
        col *= 0.95 + 0.08 * along;
        uint idx = autumn ? h % 6u : h % 7u;
        bool pasture = !autumn && (idx == 0u || idx == 5u);
        float spacing = pasture ? 14.0 : 3.0 + 3.0 * fp_unit(h >> 8);
        float coord = ((h >> 24) & 1u) == 0u ? u : v;
        float rowFade = min(1.0, max(0.0, 1.0 - max(0.05, footprint) * 2.5 / spacing));
        float rowAmp = pasture ? 0.06 : 0.05 + 0.07 * fp_unit(h >> 16);
        col *= 1.0 + rowAmp * sin(coord / spacing * 6.2831853) * rowFade;
        float edge = min(min(tu * PU, (1.0 - tu) * PU), min(tv * PV, (1.0 - tv) * PV));
        float fp = max(0.05, footprint);
        float hw = min(HW, max(0.3, 1.5 * fp));
        float cover = 1.0 - min(1.0, max(0.0, (edge - hw) / fp + 0.5));
        float strength = min(1.0, 2.0 * hw / fp);
        float gaps = fp_noise(u / 18.0, v / 18.0, seed ^ 0x77u) > -0.55 ? 1.0 : 0.0;
        float hedgeAmount = cover * strength * gaps;
        return col + (float3(0.46, 0.56, 0.52) - col) * hedgeAmount;
    }

    constant float3 fpRoofs[5] = { float3(0.050, 0.050, 0.055), float3(0.170, 0.060, 0.040), float3(0.080, 0.090, 0.100),
        float3(0.250, 0.090, 0.050), float3(0.200, 0.200, 0.190) };
    /// Mirror of SFPreview.FieldPattern.town (suburb impostor beyond the building radius).
    static float3 townColour(float x, float y, float footprint, float3 lawn, uint seed) {
        const float3 street = float3(0.060, 0.060, 0.065);
        float c = cos(0.55f), s = sin(0.55f);
        float u = c * x + s * y, v = -s * x + c * y;
        float bu = floor(u / 90.0), bv = floor(v / 140.0);
        float lu = u - bu * 90.0, lv = v - bv * 140.0;
        float roadEdge = min(min(lu, 90.0 - lu), min(lv, 140.0 - lv));
        float3 mean = street * 0.14 + float3(0.150, 0.098, 0.087) * 0.075 + lawn * 0.765;
        float fp = max(0.05, footprint);
        float detailW = 1.0 - min(1.0, max(0.0, (fp - 3.0) / 12.0));
        if (detailW <= 0.0) return mean;
        float3 col;
        if (roadEdge < 4.0) {
            col = street;
        } else {
            float row = lv < 70.0 ? 0.0 : 1.0;
            float lotI = floor((lu - 4.0) / 18.0);
            uint h = fp_hash(int(bu) * 8 + int(lotI), int(bv) * 2 + int(row), seed ^ 0x70E1u);
            float lx = lu - 4.0 - lotI * 18.0 - 9.0;
            float ly = (row == 0.0 ? lv - 4.0 : 136.0 - lv) - 22.0;
            float jx = (fp_unit(h) - 0.5) * 3.0, jy = (fp_unit(h >> 8) - 0.5) * 4.0;
            bool built = fp_unit(h >> 16) < 0.86;
            if (built && abs(lx - jx) < 5.0 && abs(ly - jy) < 6.0) {
                col = fpRoofs[h % 5u];
            } else {
                col = lawn;
                if (built && abs(lx - jx) < 5.0 && ly - jy > 6.0 && ly - jy < 9.0) col *= 0.55;
                float tx = lx - (fp_unit(h >> 4) - 0.5) * 10.0, ty = ly - 18.0;
                if (fp_unit(h >> 12) < 0.45 && tx * tx + ty * ty < 16.0) col = lawn * float3(0.45, 0.55, 0.45);
            }
        }
        return mean + (col - mean) * detailW;
    }

    /// CI check: FieldPattern factors (or town colours on lawn 0.10/0.12/0.06 when params.z = 1) on the GPU
    /// (in: x, y, footprint; params: seed, autumn, town).
    kernel void field_factors(const device float4* pts [[buffer(0)]], device float4* out [[buffer(1)]],
                              constant float4& params [[buffer(2)]], texture2d<float> dummy [[texture(0)]],
                              uint i [[thread_position_in_grid]]) {
        float4 p = pts[i];
        out[i] = params.z > 0.5 ? float4(townColour(p.x, p.y, p.z, float3(0.10, 0.12, 0.06), uint(params.x)), 0.0)
                                : float4(fieldFactor(p.x, p.y, p.z, uint(params.x), params.y > 0.5),
                                         fieldCoverage(p.x, p.y, p.w, uint(params.x), 0.12, float4(0.0), dummy));
    }

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

    /// Inverse of the ACES fit below (y in [0, 0.99]): the HDR value that tone-maps to `y`.
    static float3 acesInverse(float3 y) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        y = min(y, float3(0.99));
        float3 A = y * c - a, B = y * d - b, C = y * e;
        return max(float3(0.0), (-B - sqrt(max(float3(0.0), B * B - 4.0 * A * C))) / (2.0 * A));
    }

    static float3 acesW(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    fragment float4 world_fragment(WorldVarying in [[stage_in]], constant WorldUniforms& u [[buffer(1)]],
                                   texture3d<float> ins [[texture(0)]], texture3d<float> tr [[texture(1)]],
                                   depth2d_array<float> sm [[texture(2)]],
                                   texture2d<float> imgNear [[texture(3)]], texture2d<float> imgFar [[texture(4)]],
                                   texture2d<float> waterMask [[texture(5)]], texture2d<float> parcels [[texture(6)]]) {
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
        float shoreWm = 0.0;                                 // water-mask value (imagery water) for shoreline foam
        if (m == 8.0) {
            float2 w = in.rel.xy + u.cameraLocal.xy;
            float2 nuv = (w - (u.imageryNear.xy - u.imageryNear.z)) / (2.0 * u.imageryNear.z);
            nuv.y = 1.0 - nuv.y;                                   // row 0 = north edge
            float2 fuv = (w - (u.imageryFar.xy - u.imageryFar.z)) / (2.0 * u.imageryFar.z);
            fuv.y = 1.0 - fuv.y;
            bool inNear = u.imageryNear.w > 0.5 && all(nuv > 0.002) && all(nuv < 0.998);
            float3 farC = u.imageryFar.w > 0.5 ? imgFar.sample(imgSampler, fuv).rgb : float3(0.12, 0.14, 0.10);
            // Feather the near layer into the far one over the outer 6 % (no hard seam at the boundary).
            float edgeN = min(min(nuv.x, nuv.y), min(1.0 - nuv.x, 1.0 - nuv.y));
            float wNear = inNear ? smoothstep(0.002, 0.06, edgeN) : 0.0;
            float3 c = wNear > 0.0 ? mix(farC, imgNear.sample(imgSampler, nuv).rgb, wNear) : farC;
            // Same photo→albedo conversion as SFPreview.ImageryGround (textures are sRGB, so c is linear).
            albedo = pow(max(c, 0.0), 1.12) * 0.72;
            float wm = inNear ? waterMask.sample(imgSampler, nuv).r : 0.0;
            if (saturate((wm - 0.35) / 0.25) > 0.5) { imageryWater = true; albedo *= 0.7; shoreWm = wm; }
            m = imageryWater ? 1.0 : 7.0;
        }
        float2 fieldW = in.rel.xy + u.cameraLocal.xy;
        float fieldFp = length(fwidth(fieldW));              // derivatives outside divergent branches
        float fieldBand = max(0.12, 2.5 * fwidth(in.field));
        if (m == 7.0 && in.material == 7.0 && u.skyHorizon.w > 0.5 && in.field < -0.003) {
            albedo = mix(albedo, townColour(fieldW.x, fieldW.y, fieldFp, albedo, uint(u.ambientGround.w)), min(1.0, -in.field));
        }
        float fieldCov = 0.0;
        if (m == 7.0 && in.material == 7.0 && u.skyHorizon.w > 0.5 && in.field > 0.003) {
            // Field parcels with crisp hedgerows per pixel (the vertex grid blurred and stepped them).
            fieldCov = fieldCoverage(fieldW.x, fieldW.y, in.field, uint(u.ambientGround.w), fieldBand, u.fieldGrid, parcels);
            if (fieldCov > 0.0) {
                float3 f = fieldFactor(fieldW.x, fieldW.y, fieldFp, uint(u.ambientGround.w), u.skyHorizon.w > 1.5);
                albedo *= 1.0 + (f - 1.0) * fieldCov;
                float2 rt = fieldRowTilt(fieldW.x, fieldW.y, fieldFp, uint(u.ambientGround.w), u.skyHorizon.w > 1.5) * fieldCov;
                n = normalize(n + float3(rt, 0.0));
            }
        }
        if (m == 7.0 && dist < (in.material == 8.0 ? 350.0 : 1400.0)) {
            // Per-pixel ground detail (as SFPreview). Each octave fades out once its cell shrinks
            // below about two pixels (screen-space footprint from fwidth), so it never aliases.
            float2 w = in.rel.xy + u.cameraPos.xy;
            float fp = length(fwidth(w));
            float wFine = saturate(1.0 - fp / 1.0), wMid = saturate(1.0 - fp / 4.0), wDry = saturate(1.0 - fp / 16.0);
            float fade = (1.0 - dist / 1400.0) * (1.0 - 0.7 * fieldCov);   // fields carry their own rows
            float fine = groundNoise(w, 2.0), mid = groundNoise(w + 17.0, 8.0), dry = groundNoise(w - 31.0, 32.0);
            albedo *= 1.0 + (fine * 0.08 * wFine + mid * 0.06 * wMid) * fade;
            albedo *= 1.0 + (float3(1.10, 1.02, 0.80) - 1.0) * (max(0.0, dry) * 0.45 * wDry * fade);
            float e = 0.6;
            float gx = groundNoise(w + float2(e, 0), 2.0) - groundNoise(w - float2(e, 0), 2.0);
            float gy = groundNoise(w + float2(0, e), 2.0) - groundNoise(w - float2(0, e), 2.0);
            n = normalize(n + float3(-gx, -gy, 0.0) * (0.12 * wFine * fade));
        }
        if (m == 7.0 && in.material == 7.0 && n.z < 0.9) {
            // Steep ground: fall-line gullies, rock tone variation, scrub and scree (as SFPreview), each
            // octave faded by pixel footprint so big slopes keep detail far away.
            float steep = smoothstep(0.9, 0.7, n.z);
            float2 w = fieldW;      // true region metres (no jump at the 4 km noise wrap)
            float2 hz = n.xy; float hl = length(hz);
            float2 fall = hl > 1e-4 ? hz / hl : float2(1, 0), perp = float2(-fall.y, fall.x);
            // Triplanar on the vertical planes (horizontal axis × height), rotation-free (no wood-grain swirl).
            float wz = in.rel.z + u.cameraLocal.z;
            float ax = abs(n.x), ay = abs(n.y), asum = max(1e-3, ax + ay);
            #define TRI(ah, bv, off, dh, dz) ((ax * groundNoise(float2((w.y + (dh)) + (off) * (ah), (wz + (dz)) * (ah) / (bv)), ah) + \
                                              ay * groundNoise(float2((w.x + (dh)) - (off) * (ah), (wz + (dz)) * (ah) / (bv) - 7.0 * (ah)), ah)) / asum)
            float gw = saturate(1.0 - fieldFp * 2.5 / 14.0) * steep;
            if (gw > 0.0) {
                float g = TRI(14.0, 70.0, 51.0, 0.0, 0.0), gp = TRI(14.0, 70.0, 51.0, 1.5, 0.0);
                float dg = (gp - g) / 1.5 * 14.0;
                n = normalize(n + float3(perp * (-dg * 0.35 * gw), 0.0));
                albedo *= 1.0 - 0.28 * max(0.0, -g) * gw;
            }
            float bw = saturate(1.0 - fieldFp * 2.5 / 45.0) * steep;
            if (bw > 0.0) {
                float b0 = TRI(45.0, 160.0, 91.0, 0.0, 0.0), b1 = TRI(45.0, 160.0, 91.0, 4.0, 0.0);
                float db = (b1 - b0) / 4.0 * 45.0;
                n = normalize(n + float3(perp * (-db * 0.45 * bw), 0.0));
                float streak = TRI(9.0, 220.0, -41.0, 0.0, 0.0), ledge = TRI(320.0, 28.0, 13.0, 0.0, 0.0);
                albedo *= (1.0 - 0.22 * max(0.0, streak) * bw) * (1.0 + 0.12 * max(0.0, ledge) * bw) * (1.0 - 0.10 * max(0.0, -b0) * bw);
            }
            float cw = saturate(1.0 - fieldFp * 2.5 / 4.0) * steep;
            if (cw > 0.0) {
                float cr = TRI(4.0, 10.0, -19.0, 0.0, 0.0), crp = TRI(4.0, 10.0, -19.0, 0.5, 0.0);
                float ld = TRI(25.0, 3.5, 7.0, 0.0, 0.0), ldp = TRI(25.0, 3.5, 7.0, 0.0, 0.5);
                float dc = (crp - cr) / 0.5 * 4.0, dl = (ldp - ld) / 0.5 * 3.5;
                n = normalize(n + float3(perp * (-dc * 0.22 * cw) + fall * (dl * 0.18 * cw), 0.0));
                albedo *= 1.0 - 0.12 * max(0.0, -cr) * cw;
            }
            #undef TRI
            float big = groundNoise(w - 13.0, 64.0) * saturate(1.0 - fieldFp * 2.5 / 64.0);
            float small = groundNoise(w + 3.0, 8.0) * saturate(1.0 - fieldFp * 2.5 / 8.0);
            albedo *= 1.0 + (0.22 * big + 0.10 * small) * steep;
            if (dot(albedo, float3(0.3, 0.6, 0.1)) < 0.3) {
                float patch = groundNoise(w + 71.0, 32.0) * saturate(1.0 - fieldFp * 2.5 / 32.0);
                float scrub = smoothstep(0.14, 0.36, patch) * steep * smoothstep(0.76, 0.84, n.z);
                float scree = smoothstep(-0.2, -0.42, patch) * steep;
                albedo = mix(albedo, float3(0.050, 0.072, 0.030), scrub * 0.75);
                albedo *= 1.0 + 0.35 * scree;
            }
        }
        float ndl = dot(n, toSun);
        float vis = toSun.z > -0.05 ? shadowVisibility(u, sm, in.rel, n, dist, max(0.0f, ndl)) : 0.0;
        if (u.clouds.shape.z > 0.0 && toSun.z > 0.05 && vis > 0.0) {
            // Cloud shadow: optical depth along the sun ray through the cumulus slab (3 samples).
            float3 wp = in.rel + u.cameraLocal.xyz;
            float thick = u.clouds.shape.y, od = 0.0;
            for (int k = 0; k < 3; k++) {
                float z = u.clouds.shape.x + thick * (0.12 + 0.18 * float(k));   // the lower half holds the mass
                float t = (z - wp.z) / toSun.z;
                if (t > 0.0) od += cl_density(wp + toSun * t, u.clouds);
            }
            od *= thick / 3.0 / toSun.z;
            vis *= max(0.12, exp(-0.35 * od));     // multiple scattering keeps cloud shadows soft, never black
        }
        float3 ambient = mix(u.ambientGround.rgb, u.ambientSky.rgb, n.z * 0.5 + 0.5);
        float3 col;
        if (m == 1.0) {                                      // water
            // Wind waves: two octaves of slope noise (14 m and 3.5 m), faded by pixel footprint so
            // distant water calms to a mirror-like sheen instead of aliasing.
            float2 ww = fieldW;
            float wFar = saturate(1.0 - fieldFp * 2.5 / 14.0), wNear = saturate(1.0 - fieldFp * 2.5 / 3.5);
            float2 slope = float2(groundNoise(ww + float2(0.7, 0.0), 14.0) - groundNoise(ww - float2(0.7, 0.0), 14.0),
                                  groundNoise(ww + float2(0.0, 0.7), 14.0) - groundNoise(ww - float2(0.0, 0.7), 14.0)) * 0.9 * wFar
                         + float2(groundNoise(ww + float2(0.2, 0.0) + 31.0, 3.5) - groundNoise(ww - float2(0.2, 0.0) + 31.0, 3.5),
                                  groundNoise(ww + float2(0.0, 0.2) + 31.0, 3.5) - groundNoise(ww - float2(0.0, 0.2) + 31.0, 3.5)) * 0.7 * wNear;
            float3 wn = normalize(float3(-slope, 1.0));
            float3 r = reflect(dir, wn);
            r.z = abs(r.z);
            float cosT = max(0.0, -dot(dir, wn));
            float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            // Sky gradient in the reflection: horizon colour low, deeper sky colour higher up.
            float3 skyR = mix(u.skyHorizon.rgb, u.ambientSky.rgb * 1.6, saturate(pow(r.z, 0.6)));
            float glitter = pow(max(0.0, dot(r, toSun)), 900.0) * 60.0 + pow(max(0.0, dot(r, toSun)), 60.0) * 0.6;
            float3 refl = skyR + u.sunColour.rgb * glitter * vis;
            float3 body = albedo * (ambient * 0.6 + u.sunColour.rgb * max(0.0, toSun.z) * 0.15);
            float reflScale = imageryWater ? 0.6 : 1.0;          // wind-roughened open water
            col = mix(body, refl * reflScale, min(1.0, 0.08 + fres * (imageryWater ? 0.85 : 1.0)));
            if (imageryWater) {
                // Shoreline foam: the mask's transition band (wm 0.6–0.8), broken up by noise.
                float band = 1.0 - smoothstep(0.6, 0.8, shoreWm);
                float breakUp = smoothstep(-0.1, 0.4, groundNoise(ww + 77.0, 4.0)) * wNear + 0.35 * (1.0 - wNear);
                float foam = band * breakUp * 0.8;
                col = mix(col, float3(0.85, 0.88, 0.88) * (u.sunColour.rgb * max(0.0, toSun.z) * vis + ambient), foam);
            }
        } else if (m == 2.0) {                               // foliage: wrap + back-scatter
            float wrap = max(0.0, ndl * 0.55 + 0.45);
            float back = pow(max(0.0, dot(dir, toSun)), 4.0) * 0.35;
            col = albedo * (u.sunColour.rgb * (wrap + back) * vis + ambient * 0.85);
        } else if (m == 6.0 || m == 5.0) {                   // aircraft paint / glass: GGX
            float rough = m == 6.0 ? 0.24 : 0.06;   // glossy paint: a visible sun glint
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
        return float4(col * u.sunColour.w, 1.0);    // linear HDR (× exposure); tone-mapped in post
    }

    // Spinning propeller disc: translucent blur, denser toward the blade tips, painted tip ring, opaque
    // spinner; slight two-blade modulation. Body axes: disc centred at (x, 0, −0.05), radius 0.95 m.
    fragment float4 prop_fragment(WorldVarying in [[stage_in]], constant WorldUniforms& u [[buffer(1)]]) {
        float2 q = float2(in.local.y, in.local.z + 0.05);
        float r = length(q) / 0.95, th = atan2(q.y, q.x);
        float alpha = (0.07 + 0.11 * smoothstep(0.15, 0.85, r)) * (0.85 + 0.15 * cos(2.0 * th));
        float3 base = float3(0.02, 0.02, 0.022);
        if (r > 0.88) { alpha = 0.22; base = float3(0.55, 0.45, 0.08); }                 // tip paint ring
        if (r < 0.12) { alpha = 1.0; base = float3(0.25, 0.25, 0.26); }                  // spinner
        float3 n = normalize(in.normal);
        float3 dir = normalize(in.rel);
        if (dot(n, dir) > 0.0) n = -n;
        float3 ambient = mix(u.ambientGround.rgb, u.ambientSky.rgb, n.z * 0.5 + 0.5);
        float3 col = base * (u.sunColour.rgb * max(0.0, dot(n, u.sunDir.xyz)) + ambient);
        return float4(col * u.sunColour.w, alpha);
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
        // The scene buffer is linear HDR: invert the post tone map so the panel shows its own pixels.
        return float4(acesInverse(pow(saturate(c * 0.93 + glare), float3(2.2))), 1.0);
    }
    """
}
