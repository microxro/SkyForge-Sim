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
        float4x4 shadow0;         // camera-relative world → hero cascade clip (a column around the aircraft)
        float4x4 shadow1;         // near, middle and far cascades (orthographic)
        float4x4 shadow2;
        float4x4 shadow3;
        float4 cascadeSplits;     // far edge (m from the camera) of cascades 1, 2, 3; w = 1 when the hero cascade is drawn
        float4 cascadeTexel;      // texel size (m) of cascades 0…3
        float4 cascadeDepth;      // light-space depth range (m) of cascades 0…3
        float4 cameraPos;         // camera world x, y modulo 4096 m (noise period), z, w = 1: discard back faces
        float4 cameraLocal;       // camera x, y, z in region metres (imagery lookup), unused
        float4 imageryNear;       // centre x, y, half extent, 1 if present
        float4 imageryFar;        // centre x, y, half extent, 1 if present
        CloudLayerGPU clouds;     // cumulus layer for cloud shadows (coverage 0 = none)
        float4 fieldGrid;         // farmed-parcel texture origin iu0, iv0 and size (width 0 = none)
        float4 imageryDetail;     // sharp inner imagery square: centre x, y, half extent, 1 if present
        float4 imageryMid;        // middle-distance imagery square: centre x, y, half extent, 1 if present
        float4 skyZenith;         // rgb zenith sky radiance (reflections), w = time (s)
        float4 quality;           // x = shadow filter half width (taps), y = cabin interior fill (cockpit pass), z, w unused
        float4 runwayA;           // low threshold x, y (region metres), direction x, y (unit, toward the high end)
        float4 runwayB;           // length, width (m), low-end number (0 = none), 1 if a runway is drawn
    };

    struct BuildingVertex { packed_float3 position; char4 normal; uchar4 colour; packed_float2 uv; uchar4 style; };

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

    vertex float4 shadow_building_vertex(const device BuildingVertex* v [[buffer(0)]], constant ShadowUniforms& u [[buffer(1)]],
                                         uint vid [[vertex_id]]) {
        return u.lightViewProj * (u.model * float4(float3(v[vid].position), 1.0));
    }

    // Per-instance tree shape from a hash of the position: crown width 0.8–1.25×, height squash 0.88–1.12×
    // and a slight lean, so neighbouring crowns stop reading as identical lollipops (art round 7). Shared by
    // the main and shadow passes so shadows match their trees. Trunks keep their width.
    static float3 treeShape(float3 local, bool bark, float3 pos, thread float& crownW, thread float& sz, thread float2& cs) {
        uint h = as_type<uint>(int(floor(pos.x * 4.0))) * 0x8DA6B343u ^ as_type<uint>(int(floor(pos.y * 4.0))) * 0xD8163841u ^ 0x7A3Eu;
        h ^= h >> 13; h *= 0x5BD1E995u; h ^= h >> 15;
        float u0 = float(h & 0xFFu) / 255.0, u1 = float((h >> 8) & 0xFFu) / 255.0;
        float u2 = float((h >> 16) & 0xFFu) / 255.0, u3 = float((h >> 24) & 0xFFu) / 255.0;
        crownW = bark ? 1.0 : 0.8 + 0.45 * u0;
        sz = 0.88 + 0.24 * u1;
        cs = normalize(float2(u3 - 0.5, u0 - 0.5) + float2(0.001, 0.0));      // yaw: same-variant trees stop repeating
        float2 xy = float2(cs.x * local.x - cs.y * local.y, cs.y * local.x + cs.x * local.y);
        float3 sl = float3(xy.x * crownW, xy.y * crownW, local.z * sz);
        sl.xy += (float2(u2, u3) - 0.5) * 0.12 * local.z;      // lean (no trig: this runs per vertex, per pass)
        return sl;
    }

    vertex float4 shadow_tree_vertex(const device TerrainVertex* v [[buffer(0)]], constant ShadowUniforms& u [[buffer(1)]],
                                     const device TreeInstanceGPU* inst [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        TreeInstanceGPU t = inst[iid];
        float crownW, sz; float2 cs;
        float3 p = treeShape(float3(v[vid].position), v[vid].normal.w < 0, float3(t.position), crownW, sz, cs) * t.height + float3(t.position);
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
        float2 uv;                // buildings: metres along the wall (centred), storeys above the base
        float4 style;             // buildings: seed, style, wall length (m), storeys
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
        o.uv = float2(0.0); o.style = float4(0.0);
        return o;
    }

    vertex WorldVarying building_vertex(const device BuildingVertex* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                        uint vid [[vertex_id]]) {
        BuildingVertex w = v[vid];
        float4 p = u.model * float4(float3(w.position), 1.0);
        WorldVarying o;
        o.position = u.viewProj * p;
        o.rel = p.xyz;
        o.normal = normalize(float3(w.normal.xyz) / 127.0);
        float3 c = float3(w.colour.rgb) / 255.0;
        o.albedo = c * c;
        o.material = float(w.colour.a);
        o.field = 0.0;
        o.local = float3(w.position);
        o.uv = float2(w.uv);
        o.style = float4(float(w.style.x), float(w.style.y), float(w.style.z), float(w.style.w));
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
        o.uv = float2(0.0); o.style = float4(0.0);
        return o;
    }

    vertex WorldVarying tree_vertex(const device TerrainVertex* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                    const device TreeInstanceGPU* inst [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        TreeInstanceGPU t = inst[iid];
        TerrainVertex w = v[vid];
        float3 local = float3(w.position);
        float crownW, sz; float2 cs;
        float3 sl = treeShape(local, w.normal.w < 0, float3(t.position), crownW, sz, cs);
        float4 p = u.model * float4(sl * t.height + float3(t.position), 1.0);
        WorldVarying o;
        o.position = u.viewProj * p;
        o.rel = p.xyz;
        float3 n0 = float3(w.normal.xyz) / 127.0;
        float2 nxy = float2(cs.x * n0.x - cs.y * n0.y, cs.y * n0.x + cs.x * n0.y);
        o.normal = normalize(float3(nxy.x / crownW, nxy.y / crownW, n0.z / sz));   // inverse-transpose of the scale
        // Trunk vertices (marked by a negative normal w) are bark-coloured.
        o.albedo = w.normal.w < 0 ? float3(0.06, 0.045, 0.03) : float3(t.colour) * (0.85 + 0.3 * saturate(local.z));
        o.material = w.normal.w < 0 ? 0.0 : 2.0;
        o.field = w.normal.w < 0 ? 1.0 : float(w.normal.w) / 127.0;      // leaf: how much sky the vertex sees
        o.local = float3(0.0);
        o.uv = float2(0.0); o.style = float4(0.0);
        return o;
    }

    constexpr sampler imgSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, coord::normalized, max_anisotropy(16));   // 16: photo ground smeared at grazing angles (round 18)

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

    /// PCF (hardware comparison, (2r+1)² taps) in one cascade; 1 = lit.
    static float shadowTaps(depth2d_array<float> sm, float2 uv, float z, uint layer, int r) {
        float2 ts = 1.0 / float2(sm.get_width(), sm.get_height());
        float lit = 0.0;
        for (int y = -r; y <= r; y++) for (int x = -r; x <= r; x++)
            lit += sm.sample_compare(shadowCmp, uv + float2(x, y) * ts, layer, z);
        float n = float(2 * r + 1);
        return lit / (n * n);
    }

    /// Sun visibility: the distance-chosen cascade (1…3), combined with the hero cascade (0), a tight
    /// column around the aircraft that holds only the airframe, so its self-shadowing and its shadow on
    /// the ground stay crisp at any height. 1 = lit.
    static float shadowVisibility(constant WorldUniforms& u, depth2d_array<float> sm, float3 rel, float3 n, float dist, float ndl) {
        if (u.tableDims.w < 1.0) return 1.0;
        float tanT = sqrt(max(0.0, 1.0 - ndl * ndl)) / max(ndl, 0.05);
        int r = int(u.quality.x);
        float vis = 1.0;
        int c = dist < u.cascadeSplits.x ? 1 : (dist < u.cascadeSplits.y ? 2 : (dist < u.cascadeSplits.z ? 3 : -1));
        if (c > 0) {
            float texel = c == 1 ? u.cascadeTexel.y : (c == 2 ? u.cascadeTexel.z : u.cascadeTexel.w);
            float range = c == 1 ? u.cascadeDepth.y : (c == 2 ? u.cascadeDepth.z : u.cascadeDepth.w);
            // Normal offset + slope-scaled bias (as the CPU preview).
            float3 p = rel + n * texel * 1.5;
            float4 lp = (c == 1 ? u.shadow1 : (c == 2 ? u.shadow2 : u.shadow3)) * float4(p, 1.0);
            float2 uv = lp.xy * float2(0.5, -0.5) + 0.5;
            if (all(uv > 0.0) && all(uv < 1.0)) {
                float bias = texel * (0.8 + min(16.0, tanT * 1.4)) / range;   // low-sun acne (art review)
                vis = shadowTaps(sm, uv, lp.z - bias, uint(c), c == 3 ? min(r, 1) : r);
            }
        }
        if (u.cascadeSplits.w > 0.5) {
            float texel = u.cascadeTexel.x;
            float3 p = rel + n * texel * 2.0;
            float4 lp = u.shadow0 * float4(p, 1.0);
            float2 uv = lp.xy * float2(0.5, -0.5) + 0.5;
            if (all(uv > 0.003) && all(uv < 0.997) && lp.z > 0.0 && lp.z < 1.0) {
                float bias = texel * (1.5 + min(12.0, tanT * 1.5)) / u.cascadeDepth.x;
                vis = min(vis, shadowTaps(sm, uv, lp.z - bias, 0u, max(r, 1)));
            }
        }
        return vis;
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
    /// Antialiased seam of width `lw` (m) repeating every `period` m along `coord`; `fp` = pixel footprint.
    static float panelLine(float coord, float period, float lw, float fp) {
        float d = abs(fract(coord / period + 0.5) - 0.5) * period;
        return 1.0 - smoothstep(lw * 0.5, lw * 0.5 + fp, d);
    }
    /// Sheet-metal panel seams on the aircraft (body axes: x forward, y right, z down): fuselage frames
    /// every 0.95 m and a side seam; wing ribs every 0.9 m and two spar lines; tail ribs.
    static float aircraftPanels(float3 L, float fp) {
        float lw = 0.012, lines = 0.0;
        if (abs(L.y) < 0.75 && L.z > -0.95) {                       // fuselage
            lines = max(panelLine(L.x, 0.95, lw, fp), 1.0 - smoothstep(lw * 0.5, lw * 0.5 + fp, abs(L.z + 0.22)));
        } else if (L.z < -0.9 && abs(L.y) >= 0.75 && L.x > -1.6) {  // wings
            float spar = min(abs(L.x - (-0.15)), abs(L.x - (-0.85)));
            lines = max(panelLine(L.y, 0.9, lw, fp), 1.0 - smoothstep(lw * 0.5, lw * 0.5 + fp, spar));
        } else {                                                      // tail
            lines = panelLine(abs(L.y) + abs(L.z), 0.6, lw, fp);
        }
        return lines * saturate(1.0 - fp / 0.03);                     // gone once a pixel spans 3 cm
    }

    // Registration "N417SF" (fictitious) on both rear fuselage sides, above the stripe: 5×7 bitmap glyphs,
    // 22 cm tall, one row per byte, bit 4 = leftmost column.
    constant uchar regGlyphs[42] = {
        0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11,   // N
        0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02,   // 4
        0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E,   // 1
        0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08,   // 7
        0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E,   // S
        0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10 }; // F
    static float regCell(int cu, int cv) {
        if (cu < 0 || cv < 0 || cv > 6) return 0.0;
        int g = cu / 6, col = cu % 6;
        if (g > 5 || col > 4) return 0.0;
        return float((regGlyphs[g * 7 + cv] >> (4 - col)) & 1u);
    }
    /// Coverage of the registration at body-axes point `L` (x fwd, y right, z down) for a pixel footprint
    /// `fp` metres: bilinear glyph cells thresholded over one pixel, so edges stay smooth at any distance.
    static float registrationMark(float3 L, float fp) {
        const float cell = 0.22 / 7.0, zTop = -0.64, xAft = -3.0, xFwd = xAft + 35.0 * cell;
        if (abs(L.y) < 0.2) return 0.0;
        float v = (L.z - zTop) / cell;
        // Reads left to right from either side: aft-to-forward on the right, forward-to-aft on the left.
        float u = (L.y > 0.0 ? (L.x - xAft) : (xFwd - L.x)) / cell;
        if (v < -1.0 || v > 8.0 || u < -1.0 || u > 36.0) return 0.0;
        float fu = u - 0.5, fv = v - 0.5;
        int iu = int(floor(fu)), iv = int(floor(fv));
        float tu = fu - floor(fu), tv = fv - floor(fv);
        float b = mix(mix(regCell(iu, iv), regCell(iu + 1, iv), tu), mix(regCell(iu, iv + 1), regCell(iu + 1, iv + 1), tu), tv);
        float aa = max(fp / cell, 0.05);
        return smoothstep(0.5 - aa, 0.5 + aa, b) * mix(1.0, 0.5, saturate(fp / 0.08));
    }

    // Near-ground detail materials for real imagery. Within ~800 m a ~1 m/px photo is magnified to
    // many pixels per texel, so it carries only low-frequency colour; each photo pixel is classified
    // (grass, dry grass, bare soil, pavement or roof; canopy and water have their own paths) and the
    // class supplies the high frequencies: blades and clumps, tufts and streaks, pebbles and clods,
    // aggregate, patches and cracks. Every octave fades once its cell spans about two pixels.
    struct GroundClasses { float grass, dry, soil, pave; };
    static GroundClasses classifyGround(float3 c, float forest) {
        float hi = max(c.r, max(c.g, c.b)), lo = min(c.r, min(c.g, c.b));
        float chroma = (hi - lo) / max(hi, 1e-3);            // saturation of the linear photo colour
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        GroundClasses k;
        k.grass = smoothstep(0.0, 0.03, c.g - max(c.r, c.b) * 0.92) * (1.0 - forest);
        k.dry = smoothstep(0.08, 0.25, (c.r - c.b) / max(hi, 1e-3)) * smoothstep(0.02, 0.10, l) * (1.0 - k.grass);
        k.pave = smoothstep(0.22, 0.10, chroma) * (1.0 - k.grass);
        k.soil = max(0.0, 1.0 - k.grass - k.dry - k.pave) * (1.0 - forest);
        float sum = max(1e-3, k.grass + k.dry + k.soil + k.pave);
        float scale = (1.0 - forest) / sum;
        k.grass *= scale; k.dry *= scale; k.soil *= scale; k.pave *= scale;
        return k;
    }
    /// Multiplicative albedo detail (mean ≈ 1) and a normal tilt for ground classes `k` at world point `w`
    /// (metres) with pixel footprint `fp` (metres).
    static float3 groundMaterial(GroundClasses k, float2 w, float fp, thread float2& tilt) {
        float o1 = saturate(1.0 - fp / 0.15), o2 = saturate(1.0 - fp / 0.6), o3 = saturate(1.0 - fp / 2.5), o4 = saturate(1.0 - fp / 8.0);
        float3 f = float3(1.0);
        tilt = float2(0.0);
        if (k.grass > 0.01) {
            float blades = groundNoise(w + 5.3, 0.25) * o1, clumps = groundNoise(w - 9.1, 1.2) * o2, tone = groundNoise(w + 23.0, 6.0) * o4;
            float3 g = float3(1.0 + 0.16 * blades + 0.15 * clumps);
            g *= mix(float3(1.0), float3(1.10, 1.03, 0.80), saturate(tone) * 0.6);     // sun-bleached patches
            g *= mix(float3(1.0), float3(0.86, 1.04, 0.92), saturate(-tone) * 0.6);    // lush patches
            f += (g - 1.0) * k.grass;
            float e = 0.3;
            tilt += float2(groundNoise(w + float2(e, 0) - 9.1, 1.2) - groundNoise(w - float2(e, 0) - 9.1, 1.2),
                           groundNoise(w + float2(0, e) - 9.1, 1.2) - groundNoise(w - float2(0, e) - 9.1, 1.2)) * (0.35 * o2 * k.grass);
        }
        if (k.dry > 0.01) {
            // Tufts and wind-laid streaks (stretched noise along a slowly turning direction).
            float a = 0.6 + 1.2 * groundNoise(w + 61.0, 30.0);
            float2 d = float2(cos(a), sin(a)), sw = float2(dot(w, d) / 3.0, dot(w, float2(-d.y, d.x)) * 2.0);
            float streak = groundNoise(sw + 13.0, 1.0) * o2, tuft = groundNoise(w - 3.7, 0.4) * o1, bare = groundNoise(w + 44.0, 4.0) * o3;
            float3 g = float3(1.0 + 0.14 * streak + 0.16 * tuft);
            g *= mix(float3(1.0), float3(0.90, 0.86, 0.80), saturate(bare) * 0.7);      // thin, earthy patches
            f += (g - 1.0) * k.dry;
            float e = 0.15;
            tilt += float2(groundNoise(w + float2(e, 0) - 3.7, 0.4) - groundNoise(w - float2(e, 0) - 3.7, 0.4),
                           groundNoise(w + float2(0, e) - 3.7, 0.4) - groundNoise(w - float2(0, e) - 3.7, 0.4)) * (0.25 * o1 * k.dry);
        }
        if (k.soil > 0.01) {
            float pebbles = groundNoise(w + 2.9, 0.12) * o1, clods = groundNoise(w - 17.0, 0.7) * o2, blotch = groundNoise(w + 8.0, 3.5) * o3;
            float3 g = float3((1.0 + 0.14 * pebbles) * (1.0 + 0.12 * clods) * (1.0 + 0.14 * blotch));
            g *= mix(float3(1.0), float3(0.92, 0.95, 1.02), saturate(-blotch) * 0.5);   // damp, cooler hollows
            f += (g - 1.0) * k.soil;
            float e = 0.25;
            tilt += float2(groundNoise(w + float2(e, 0) - 17.0, 0.7) - groundNoise(w - float2(e, 0) - 17.0, 0.7),
                           groundNoise(w + float2(0, e) - 17.0, 0.7) - groundNoise(w - float2(0, e) - 17.0, 0.7)) * (0.30 * o2 * k.soil);
        }
        if (k.pave > 0.01) {
            float agg = groundNoise(w + 7.7, 0.08) * o1, patch = groundNoise(w - 29.0, 5.0) * o4, stain = groundNoise(w + 91.0, 2.2) * o3;
            float crack = 1.0 - smoothstep(0.0, 0.035 + fp * 0.05, abs(groundNoise(w + 37.0, 7.0))) ;   // thin sealed cracks
            float g = (1.0 + 0.06 * agg) * (1.0 + 0.08 * patch) * (1.0 - 0.10 * saturate(-stain)) * (1.0 - 0.22 * crack * o3);
            f += (g - 1.0) * k.pave;
        }
        return f;
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

    // MARK: Shared helpers for per-pixel paint, glazing and facades

    /// Antialiased step at `edge` for a pixel footprint `fp` (same units as x).
    static float aaStep(float edge, float x, float fp) { return saturate((x - edge) / max(fp, 1e-5) + 0.5); }
    static float aaBand(float lo, float hi, float x, float fp) { return aaStep(lo, x, fp) * (1.0 - aaStep(hi, x, fp)); }
    static float sdRoundBox(float2 p, float2 c, float2 h, float r) {
        float2 q = abs(p - c) - h + r;
        return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
    }
    static float hash21(float2 p) {
        p = fract(p * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return fract((p.x + p.y) * p.x);
    }

    /// Environment radiance for glossy reflections: zenith-to-horizon sky above, a ground tone below.
    static float3 skyEnv(constant WorldUniforms& u, float3 r) {
        float3 sky = mix(u.skyHorizon.rgb, u.skyZenith.rgb, pow(saturate(r.z), 0.45));
        float3 ground = u.ambientGround.rgb * 1.6;
        return mix(ground, sky, smoothstep(-0.10, 0.05, r.z));
    }

    /// GGX specular lobe (D·G·F / 4·nl·nv, already multiplied by nl) for Fresnel reflectance `f0`.
    static float ggxLobe(float3 n, float3 v, float3 l, float rough, float f0) {
        float3 h = normalize(l + v);
        float nl = max(0.0, dot(n, l)), nv = max(1e-4, dot(n, v)), nh = max(0.0, dot(n, h)), vh = max(0.0, dot(v, h));
        float a = rough * rough, a2 = a * a;
        float dd = nh * nh * (a2 - 1.0) + 1.0;
        float D = a2 / (3.14159265 * dd * dd);
        float k = (rough + 1.0) * (rough + 1.0) / 8.0;
        float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
        float F = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
        return D * G * F / max(1e-4, 4.0 * nl * nv) * nl;
    }

    // MARK: SF-1 skin (mirror of SFWorldGen.AircraftLivery; body axes x forward, y right, z down)

    constant float fusRoofX[9] = { 1.36, 1.10, 0.80, 0.52, 0.0, -0.70, -1.40, -1.75, -2.05 };
    constant float fusRoofZ[9] = { -0.54, -0.69, -0.87, -1.015, -1.03, -1.03, -1.0, -0.88, -0.79 };
    static float fuselageRoof(float x) {
        if (x >= fusRoofX[0]) return fusRoofZ[0];
        for (int i = 0; i < 8; i++) {
            if (x >= fusRoofX[i + 1]) return mix(fusRoofZ[i + 1], fusRoofZ[i], (x - fusRoofX[i + 1]) / (fusRoofX[i] - fusRoofX[i + 1]));
        }
        return fusRoofZ[8];
    }
    static float liveryStripeZ(float x) {
        float t = saturate((2.45 - x) / 7.9);
        return -0.03 - 0.24 * t * t * (3.0 - 2.0 * t) - 0.03 * t;
    }

    constant float3 skinWhite = float3(0.80, 0.80, 0.78);
    constant float3 skinNavy = float3(0.012, 0.032, 0.105);
    constant float3 skinOrange = float3(0.78, 0.20, 0.022);

    struct Skin {
        float3 albedo;
        float glass;      // 1 = glazing
        float matte;      // 1 = no clear coat (anti-glare paint, rubber)
        float3 emissive;
    };

    /// Fuselage: glazing, gaskets, anti-glare panel, stripe, door and cowl seams.
    static Skin fuselageSkin(float3 L, float fp) {
        Skin s; s.albedo = skinWhite; s.glass = 0.0; s.matte = 0.0; s.emissive = float3(0.0);
        float roof = fuselageRoof(L.x);
        float ay = abs(L.y);
        // Glazing: windscreen (wraps to the door posts), door and rear side windows, rear window.
        float wind = aaBand(0.56, 1.335, L.x, fp) * (1.0 - aaStep(-0.575, L.z, fp));
        float windFrame = aaBand(0.535, 1.36, L.x, fp) * (1.0 - aaStep(-0.553, L.z, fp));
        float side = aaStep(0.30, ay, fp);
        float sdDoor = sdRoundBox(L.xz, float2(0.05, -0.7225), float2(0.41, 0.2225), 0.07);
        float sdRear = sdRoundBox(L.xz, float2(-0.90, -0.7225), float2(0.40, 0.2225), 0.07);
        float sdSide = min(sdDoor, sdRear);
        float sideGlass = side * (1.0 - aaStep(0.0, sdSide, fp));
        float sideFrame = side * (1.0 - aaStep(0.02, sdSide, fp));
        float back = aaBand(-1.98, -1.47, L.x, fp) * (1.0 - aaStep(0.33, ay, fp)) * (1.0 - aaStep(roof + 0.10, L.z, fp));
        float backFrame = aaBand(-2.0, -1.45, L.x, fp) * (1.0 - aaStep(0.35, ay, fp)) * (1.0 - aaStep(roof + 0.12, L.z, fp));
        float glass = max(max(wind, sideGlass), back);
        float frame = max(max(windFrame, sideFrame), backFrame);
        // Stripe along the side: navy band with an orange pinstripe above it.
        float t = saturate((2.45 - L.x) / 7.9);
        float d = L.z - liveryStripeZ(L.x);
        float w = 0.075 + 0.05 * t;
        float onSide = aaStep(0.02, ay, fp) * (1.0 - aaStep(2.45, L.x, fp));
        float navy = (1.0 - aaStep(w, abs(d), fp)) * onSide;
        float orange = aaBand(-w - 0.06, -w - 0.03, d, fp) * onSide;
        s.albedo = mix(s.albedo, skinNavy, navy);
        s.albedo = mix(s.albedo, skinOrange, orange);
        // Anti-glare panel ahead of the windscreen.
        float glare = aaBand(1.37, 2.42, L.x, fp) * (1.0 - aaStep(0.27, ay, fp)) * (1.0 - aaStep(-0.38, L.z, fp));
        s.albedo = mix(s.albedo, float3(0.012, 0.012, 0.013), glare);
        s.matte = glare;
        // Seams: door outline, cowl split and firewall lines, fading once a pixel spans ~4 cm.
        float lw = 0.006, vis = saturate(1.0 - fp / 0.04);
        float door = side * (1.0 - aaStep(lw, abs(sdRoundBox(L.xz, float2(0.04, -0.37), float2(0.47, 0.63), 0.07)), fp));
        float cowl = aaBand(1.60, 2.50, L.x, fp) * (1.0 - aaStep(lw, abs(L.z + 0.10), fp)) * side;
        float fire = (1.0 - aaStep(lw, abs(L.x - 1.585), fp));
        float seams = max(max(door, cowl), fire) * vis * (1.0 - glare);
        s.albedo *= 1.0 - 0.45 * seams;
        // Gasket, then glass on top.
        float gasket = saturate(frame - glass);
        s.albedo = mix(s.albedo, float3(0.010, 0.010, 0.011), gasket);
        s.matte = max(s.matte, gasket);
        s.glass = glass;
        return s;
    }

    /// Wings, tail and fairings: tips, fin sweep, control-surface gaps, fuel caps and navigation lights.
    static Skin surfaceSkin(float3 L, float fp) {
        Skin s; s.albedo = skinWhite; s.glass = 0.0; s.matte = 0.0; s.emissive = float3(0.0);
        float ay = abs(L.y);
        bool wing = L.z < -0.9 && L.x > -1.7 && ay > 0.3;
        if (wing) {
            float chord = ay < 2.5 ? 1.63 : mix(1.63, 1.13, (ay - 2.5) / 3.0);
            float le = 0.25 - (1.63 - chord) * 0.30;
            s.albedo = mix(s.albedo, skinOrange, aaBand(5.08, 5.14, ay, fp));
            s.albedo = mix(s.albedo, skinNavy, aaStep(5.18, ay, fp));
            // Flap and aileron gaps (hinge at 72 % chord), fuel caps.
            float lw = 0.007, vis = saturate(1.0 - fp / 0.05);
            float xh = le - 0.72 * chord;
            float span = aaBand(0.62, 4.75, ay, fp) * (1.0 - aaStep(lw, abs(L.x - xh), fp));
            float aft = 1.0 - aaStep(xh, L.x, fp);
            float cuts = aft * max(max(1.0 - aaStep(lw, abs(ay - 0.62), fp), 1.0 - aaStep(lw, abs(ay - 2.58), fp)), 1.0 - aaStep(lw, abs(ay - 4.75), fp));
            s.albedo *= 1.0 - 0.55 * max(span, cuts) * vis;
            float cap = 1.0 - aaStep(0.045, length(float2(L.x + 0.20, ay - 1.25)), fp);
            s.albedo = mix(s.albedo, float3(0.55, 0.10, 0.06), cap * vis);
            // Navigation lights at the tips (red left, green right) and the landing light in the left leading edge.
            float tip = aaStep(5.40, ay, fp) * aaStep(le - 0.22, L.x, fp);
            s.emissive = tip * (L.y < 0.0 ? float3(1.6, 0.05, 0.03) : float3(0.04, 1.4, 0.25));
            float lamp = (L.y < 0.0 ? 1.0 : 0.0) * aaBand(1.95, 2.25, ay, fp) * aaStep(le - 0.035, L.x, fp);
            s.glass = lamp;
            s.emissive += lamp * float3(1.2, 1.15, 1.0);
        } else if (ay < 0.2 && L.z < -0.95 && L.x < -4.0) {
            // Fin: navy sweep with an orange pinstripe; rudder hinge line.
            float d = L.z + 1.55 + 0.75 * (L.x + 4.9);
            s.albedo = mix(s.albedo, skinOrange, aaBand(0.045, 0.10, d, fp));
            s.albedo = mix(s.albedo, skinNavy, 1.0 - aaStep(0.0, d, fp));
            float sp = saturate((-0.5 - L.z) / 1.70);
            float xh = (-4.29 - 0.86 * sp) - 0.60 * (1.42 - 0.72 * sp);
            s.albedo *= 1.0 - 0.5 * (1.0 - aaStep(0.007, abs(L.x - xh), fp)) * saturate(1.0 - fp / 0.05);
        } else if (L.x < -4.2 && L.z > -0.75 && L.z < -0.45) {
            // Tailplane: navy tips, elevator hinge line.
            s.albedo = mix(s.albedo, skinNavy, aaStep(1.52, ay, fp));
            float f = saturate(ay / 1.7);
            float xh = (-4.53 - 0.22 * f) - 0.62 * 1.05 * (1.0 - 0.32 * f);
            s.albedo *= 1.0 - 0.5 * (1.0 - aaStep(0.007, abs(L.x - xh), fp)) * saturate(1.0 - fp / 0.05);
        }
        return s;
    }

    // MARK: Building facades

    struct Facade {
        float3 albedo;
        float glass;        // glazing coverage of this pixel
        float3 interior;    // what shows through the glass (dark room, blinds)
        float f0;           // glass reflectance at normal incidence
     float3 tint; };

    /// Storeys, window bays and cladding for a wall pixel. `uv`: metres along the wall (centred) and
    /// storeys above the base; `st`: seed, style, wall length (m), storeys; `fpU`/`fpV`: pixel footprint
    /// in metres along the wall and in storeys.
    static Facade facade(float2 uv, float4 st, float3 wall, float fpU, float fpV) {
        Facade f; f.albedo = wall; f.glass = 0.0; f.interior = float3(0.012, 0.016, 0.020); f.f0 = 0.06; f.tint = float3(1.0);
        float seed = st.x, style = st.y, len = max(st.z, 1.0), storeys = max(st.w, 1.0);
        float h1 = fract(seed * 0.1031 + 0.11), h2 = fract(seed * 0.2371 + 0.47);
        float bay = style < 0.5 ? 3.4 : (style < 1.5 ? 3.0 : (style < 2.5 ? 3.6 : (style < 3.5 ? 7.0 : (style < 4.5 ? 1.7 : 3.4))));
        bay *= 0.9 + 0.25 * h1;
        float nb = max(1.0, floor(len / bay + 0.5));
        float bw = len / nb;
        float bx = (uv.x + 0.5 * len) / bw;
        float bi = floor(bx), fx = bx - bi;
        float fi = floor(uv.y), fy = uv.y - fi;
        bool inWall = uv.y >= 0.0 && uv.y < storeys;
        bool groundFloor = fi < 0.5;
        float2 w0 = float2(0.28, 0.24), w1 = float2(0.72, 0.84);
        float presence = 1.0, mean = 1.0;
        float hb = hash21(float2(bi + seed * 7.0, fi + seed * 3.0));
        if (style < 0.5) {                       // house: a window in most bays
            w0 = float2(0.30, 0.32); w1 = float2(0.70, 0.78);
            presence = step(0.22, hb); mean = 0.78;
        } else if (style < 1.5) {                // apartments: regular punched windows
            w0 = float2(0.24, 0.28); w1 = float2(0.76, 0.80);
        } else if (style < 2.5) {                // offices and shops: ribbon glazing, a shopfront at street level
            w0 = float2(0.04, 0.30); w1 = float2(0.96, 0.84);
            if (groundFloor) { w0.y = 0.06; w1.y = 0.80; }
            f.f0 = 0.10; f.tint = mix(float3(1.0), float3(0.78, 0.90, 1.0), h2);
        } else if (style < 3.5) {                // sheds: a few high windows, loading doors at ground level
            w0 = float2(0.30, 0.60); w1 = float2(0.70, 0.86);
            presence = step(0.60, hb); mean = 0.40;
            if (groundFloor && hb < 0.25) { w0 = float2(0.20, 0.0); w1 = float2(0.80, 0.78); presence = 1.0; }
        } else if (style < 4.5) {                // towers: curtain wall
            w0 = float2(0.05, 0.10); w1 = float2(0.95, 0.88);
            // Coated glass: each tower has its own reflectance and tint (blue, green, bronze or neutral).
            f.f0 = mix(0.20, 0.42, h1);
            f.tint = h2 < 0.35 ? float3(0.55, 0.74, 1.0) : (h2 < 0.60 ? float3(0.58, 0.88, 0.84) : (h2 < 0.78 ? float3(1.0, 0.80, 0.56) : float3(0.80, 0.86, 0.92)));
        }
        float ax = fpU / bw, ay = fpV;
        float win = aaBand(w0.x, w1.x, fx, ax) * aaBand(w0.y, w1.y, fy, ay) * presence;
        // Bays under about two pixels dissolve into their mean coverage instead of shimmering.
        float resolved = saturate(2.0 - 4.0 * max(ax, ay));
        float area = (w1.x - w0.x) * (w1.y - w0.y) * mean;
        win = mix(area, win, resolved) * (inWall ? 1.0 : 0.0);
        // Loading doors are painted metal, not glass.
        bool dock = style > 2.5 && style < 3.5 && groundFloor && hb < 0.25;
        // Cladding: per-panel tone, slab lines, weathering streaks, darker base, lighter coping.
        float panel = hash21(float2(bi * 1.7 + seed, fi * 2.3 + 5.0));
        float3 a = wall;
        if (style > 1.5) a *= 0.94 + 0.12 * panel * resolved;
        if (style > 2.5 && style < 3.5) a *= 1.0 + 0.05 * sin(uv.x * 20.9) * saturate(1.0 - fpU / 0.15);      // profiled sheet
        if (style < 1.5 && h2 > 0.5) {                                                                        // brick courses
            float course = 0.5 + 0.5 * sin(uv.y * 3.0 / 0.075 * 6.2831853);
            a *= 1.0 - 0.10 * course * saturate(1.0 - fpV * 3.0 / 0.04);
        }
        float slab = (style > 1.5 && style < 2.5) || style > 3.5 ? (1.0 - aaStep(0.05, fy, ay)) * resolved : 0.0;
        a *= 1.0 - 0.25 * slab;
        float streak = groundNoise(float2(uv.x * 2.2 + seed, uv.y * 0.35), 1.0);
        a *= 1.0 - 0.10 * saturate(streak) * saturate(1.0 - fpU / 1.5);
        a *= mix(0.72, 1.0, smoothstep(-0.2, 0.35, uv.y));                                                    // ground grime
        if (uv.y >= storeys) a *= 1.08;                                                                       // parapet coping
        if (uv.y < 0.0) a *= 0.6;
        if (dock) { a = mix(a, float3(0.25, 0.27, 0.30) * (0.8 + 0.4 * panel), win); win = 0.0; }
        // Behind the glass: mostly dark rooms, some blinds and lit ceilings.
        float room = hash21(float2(bi * 3.1 + seed * 0.7, fi * 1.9 + 11.0));
        float3 interior = mix(float3(0.010, 0.014, 0.018), float3(0.06, 0.065, 0.07), smoothstep(0.55, 0.9, room));
        if (room > 0.90 && style < 2.5) interior = float3(0.30, 0.29, 0.26);                                   // drawn blinds
        if (style > 3.5) interior = mix(float3(0.008, 0.016, 0.022), float3(0.02, 0.035, 0.04), h2);           // tinted
        // Frames and mullions: a thin dark line around each pane.
        float frame = win * resolved * (1.0 - aaBand(w0.x + 0.04, w1.x - 0.04, fx, ax) * aaBand(w0.y + 0.05, w1.y - 0.05, fy, ay));
        f.albedo = mix(a, float3(0.03, 0.03, 0.035), frame * 0.8);
        f.glass = win * (1.0 - frame);
        f.interior = mix(float3(0.03), interior, resolved);
        return f;
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

    /// Linear ground-photo colour at region point `w` from the imagery layers (far → middle → near →
    /// sharp detail square, each feathered into the one below), with a light unsharp mask against a
    /// coarser mip so magnified texels keep their edges. Explicit gradients: safe inside branches.
    /// A runway numeral as seven painted strokes. `p`: x 0…1 left to right, y 0…1 from the threshold side.
    static float runwayDigit(int d, float2 p, float2 aa) {
        const int masks[10] = {0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F};
        int m = masks[clamp(d, 0, 9)];
        const float tx = 0.27, ty = 0.11;
        float inX = aaBand(0.0, 1.0, p.x, aa.x);
        float left = aaBand(0.0, tx, p.x, aa.x), right = aaBand(1.0 - tx, 1.0, p.x, aa.x);
        float up = aaBand(0.5, 1.0, p.y, aa.y), down = aaBand(0.0, 0.5, p.y, aa.y);
        float c = 0.0;
        if ((m & 0x01) != 0) c = max(c, inX * aaBand(1.0 - ty, 1.0, p.y, aa.y));
        if ((m & 0x40) != 0) c = max(c, inX * aaBand(0.5 - 0.5 * ty, 0.5 + 0.5 * ty, p.y, aa.y));
        if ((m & 0x08) != 0) c = max(c, inX * aaBand(0.0, ty, p.y, aa.y));
        if ((m & 0x20) != 0) c = max(c, left * up);
        if ((m & 0x02) != 0) c = max(c, right * up);
        if ((m & 0x10) != 0) c = max(c, left * down);
        if ((m & 0x04) != 0) c = max(c, right * down);
        return c;
    }

    /// Painted markings of one runway end: `a` metres in from that threshold, `c` metres right of the
    /// centreline as seen on approach, `len`/`w` the runway, `number` its designation (0 = none), `fp` the
    /// pixel footprint (m). Threshold bars, numerals, centreline, aiming point, touchdown zone, edge lines.
    static float runwayPaint(float a, float c, float len, float w, int number, float fp) {
        float ac = abs(c), hw = 0.5 * w;
        float aaA = max(fp * 3.0, 0.02), aaC = max(fp, 0.02);      // the along axis is the foreshortened one
        float paint = aaBand(hw - 1.4, hw - 0.5, ac, aaC) * aaBand(0.0, len, a, aaA);                 // edge lines
        // Threshold: bars 1.8 m wide, 1.8 m apart, either side of a 3.6 m centre gap.
        float bars = aaBand(6.0, 36.0, a, aaA) * aaBand(1.8, hw - 2.6, ac, aaC);
        float bp = fract((ac - 1.8) / 3.6);
        float aaP = aaC / 3.6;
        paint = max(paint, bars * mix(0.5, aaBand(0.0, 0.5, bp, aaP), saturate(1.5 - aaP * 3.0)));    // unresolved bars: their mean
        // Designation: numerals 18 m tall.
        if (number > 0) {
            const float dw = 5.2, gap = 2.6, tall = 18.0;
            float2 aaD = float2(aaC / dw, aaA / tall);
            float py = (a - 48.0) / tall;
            if (py > -0.2 && py < 1.2) {
                int tens = number / 10, ones = number - tens * 10;
                paint = max(paint, runwayDigit(tens, float2((c + gap * 0.5 + dw) / dw, py), aaD));
                paint = max(paint, runwayDigit(ones, float2((c - gap * 0.5) / dw, py), aaD));
            }
        }
        // Centreline: 30 m stripes, 20 m gaps, from beyond the numerals to the runway's middle.
        float cl = aaBand(0.0, 0.45, ac, aaC) * aaStep(78.0, a, aaA) * aaBand(0.0, 0.6, fract((a - 78.0) / 50.0), aaA / 50.0);
        paint = max(paint, cl * saturate(1.5 - aaA / 25.0) + aaBand(0.0, 0.45, ac, aaC) * aaStep(78.0, a, aaA) * 0.6 * saturate(aaA / 25.0 - 0.5));
        // Aiming point and touchdown zone, on runways long enough to carry them.
        float aim = len >= 2400.0 ? 400.0 : (len >= 1500.0 ? 300.0 : 250.0);
        if (len >= 1200.0) paint = max(paint, aaBand(aim, aim + 45.0, a, aaA) * aaBand(hw * 0.24, hw * 0.24 + hw * 0.36, ac, aaC));
        if (len >= 1500.0) {
            for (int k = 0; k < 5; k++) {
                float at = 150.0 * float(k + 1) + (k >= 2 ? 150.0 : 0.0);        // 150, 300, 600, 750, 900 m
                if (abs(at - aim) < 100.0 || at > len * 0.5 - 60.0) continue;
                float n = k == 0 ? 3.0 : (k < 3 ? 2.0 : 1.0);
                float tz = fract((ac - hw * 0.24) / 3.3), inZ = aaBand(hw * 0.24, hw * 0.24 + 3.3 * n - 1.5, ac, aaC);
                paint = max(paint, aaBand(at, at + 22.5, a, aaA) * inZ * aaBand(0.0, 0.55, tz, aaC / 3.3));
            }
        }
        return saturate(paint);
    }

    /// Local contrast for a magnified photo. Where one texel covers several pixels the two footprint
    /// samples above both read mip 0, so nothing is sharpened; here the blurred references are explicit
    /// mip levels, which restores edge contrast (kerbs, roof lines, field boundaries) the bilinear
    /// magnification smears. No effect at 1:1 or when minified.
    static float3 crispen(texture2d<float> img, float2 uv, float3 c, float2 gx, float2 gy) {
        float texel = 1.0 / float(img.get_width());
        float mag = saturate(log2(max(texel / max(max(length(gx), length(gy)), 1e-9), 1.0)) / 2.0);
        if (mag <= 0.0) return c;
        float3 b1 = img.sample(imgSampler, uv, level(1.6)).rgb, b2 = img.sample(imgSampler, uv, level(3.2)).rgb;
        return max(c + ((c - b1) * 0.9 + (b1 - b2) * 0.45) * mag, float3(0.0));
    }

    static float3 photoColour(constant WorldUniforms& u, texture2d<float> imgNear, texture2d<float> imgMid, texture2d<float> imgFar,
                              texture2d<float> imgDetail, float2 w, float2 dwx, float2 dwy, thread float2& nuv, thread bool& inNear,
                              thread float& outerWater, thread float& nearWeight) {
        float3 c = float3(0.12, 0.14, 0.10);
        outerWater = 0.0; nearWeight = 0.0;
        if (u.imageryFar.w > 0.5) {
            float k = 1.0 / (2.0 * u.imageryFar.z);
            float2 uv = (w - (u.imageryFar.xy - u.imageryFar.z)) * k; uv.y = 1.0 - uv.y;
            float2 gx = float2(dwx.x, -dwx.y) * k, gy = float2(dwy.x, -dwy.y) * k;
            float4 f4 = imgFar.sample(imgSampler, uv, gradient2d(gx, gy));
            c = f4.rgb; outerWater = f4.a;
            float3 b = imgFar.sample(imgSampler, uv, gradient2d(gx * 4.0, gy * 4.0)).rgb;
            c = max(c + (c - b) * 0.3, float3(0.0));
        }
        if (u.imageryMid.w > 0.5) {
            float k = 1.0 / (2.0 * u.imageryMid.z);
            float2 uv = (w - (u.imageryMid.xy - u.imageryMid.z)) * k; uv.y = 1.0 - uv.y;
            float edge = min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y));
            if (edge > 0.002) {
                float2 gx = float2(dwx.x, -dwx.y) * k, gy = float2(dwy.x, -dwy.y) * k;
                float4 m4 = imgMid.sample(imgSampler, uv, gradient2d(gx, gy));
                float3 m = m4.rgb;
                float3 b = imgMid.sample(imgSampler, uv, gradient2d(gx * 4.0, gy * 4.0)).rgb;
                m = max(m + (m - b) * 0.35, float3(0.0));
                c = mix(c, m, smoothstep(0.002, 0.06, edge));
                outerWater = mix(outerWater, m4.a, smoothstep(0.002, 0.06, edge));
            }
        }
        float kn = 1.0 / (2.0 * max(u.imageryNear.z, 1.0));
        nuv = (w - (u.imageryNear.xy - u.imageryNear.z)) * kn; nuv.y = 1.0 - nuv.y;
        inNear = u.imageryNear.w > 0.5 && all(nuv > 0.002) && all(nuv < 0.998);
        if (inNear) {
            float2 gx = float2(dwx.x, -dwx.y) * kn, gy = float2(dwy.x, -dwy.y) * kn;
            float3 nearC = imgNear.sample(imgSampler, nuv, gradient2d(gx, gy)).rgb;
            float3 b = imgNear.sample(imgSampler, nuv, gradient2d(gx * 4.0, gy * 4.0)).rgb;
            nearC = max(nearC + (nearC - b) * 0.45, float3(0.0));
            nearC = crispen(imgNear, nuv, nearC, gx, gy);
            float edgeN = min(min(nuv.x, nuv.y), min(1.0 - nuv.x, 1.0 - nuv.y));
            nearWeight = smoothstep(0.002, 0.06, edgeN);
            c = mix(c, nearC, nearWeight);
        }
        if (u.imageryDetail.w > 0.5) {
            float k = 1.0 / (2.0 * max(u.imageryDetail.z, 1.0));
            float2 uv = (w - (u.imageryDetail.xy - u.imageryDetail.z)) * k; uv.y = 1.0 - uv.y;
            float edge = min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y));
            if (edge > 0.002) {
                float2 gx = float2(dwx.x, -dwx.y) * k, gy = float2(dwy.x, -dwy.y) * k;
                float3 d = imgDetail.sample(imgSampler, uv, gradient2d(gx, gy)).rgb;
                float3 b = imgDetail.sample(imgSampler, uv, gradient2d(gx * 4.0, gy * 4.0)).rgb;
                d = max(d + (d - b) * 0.35, float3(0.0));
                d = crispen(imgDetail, uv, d, gx, gy);
                c = mix(c, d, smoothstep(0.002, 0.08, edge));
            }
        }
        return c;
    }

    /// Photo colour → surface albedo. With the scene exposure at a real camera's level the photo's own
    /// brightness is already right, so this is near identity (a touch of contrast, 10 % under white).
    static float3 photoAlbedo(float3 c) {
        float3 a = pow(max(c, float3(0.0)), float3(1.08)) * 0.90;
        // Aerial photos are stretched so that concrete, sand and light roofs sit near white; real surfaces
        // top out near 0.6, so the top of the range is compressed. Knee 0.24, slope 0.25 (0.8 → 0.38): with the
        // 0.42/0.48 shoulder, 21–34 % of near-band pixels at KBFI and KMRY sat above 1.6× the band median and
        // read as white blotches (art round 22; rounds 17–19 used 0.20/0.32 on a darker base).
        return select(a, 0.24 + (a - 0.24) * 0.25, a > 0.24);
    }

    fragment float4 world_fragment(WorldVarying in [[stage_in]], constant WorldUniforms& u [[buffer(1)]],
                                   texture3d<float> ins [[texture(0)]], texture3d<float> tr [[texture(1)]],
                                   depth2d_array<float> sm [[texture(2)]],
                                   texture2d<float> imgNear [[texture(3)]], texture2d<float> imgFar [[texture(4)]],
                                   texture2d<float> waterMask [[texture(5)]], texture2d<float> parcels [[texture(6)]],
                                   texture2d<float> imgDetail [[texture(7)]], texture2d<float> imgMid [[texture(8)]]) {
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
        float imgForest = 0.0;                               // canopy score of the imagery colour (real terrain)
        float groundMat = 0.0;                               // weight of the near-ground detail materials
        float2 groundTilt = float2(0.0);                     // their normal tilt (applied after the normal is final)
        float roadNear = 0.0;                                // road proximity from the near mask's second channel
        float2 photoW = in.rel.xy + u.cameraLocal.xy;      // region metres (imagery lookup)
        float2 dwx = dfdx(photoW), dwy = dfdy(photoW);
        if (m == 8.0) {
            float2 nuv; bool inNear;
            float outerWater, nearWeight;
            float3 c = photoColour(u, imgNear, imgMid, imgFar, imgDetail, photoW, dwx, dwy, nuv, inNear, outerWater, nearWeight);
            // (No photo-tree suppression: lifting dark pixels to a local average also lifted building and
            // terrain shadows and left hard dark rims; art round 5 scored it a regression. The 3D trees
            // stand on the photo's foliage pixels instead, so the photo crown sits under its 3D tree.)
            float cl = dot(c, float3(0.2126, 0.7152, 0.0722));
            imgForest = smoothstep(0.0, 0.02, c.g - max(c.r, c.b)) * smoothstep(0.10, 0.03, cl);   // dark green canopy
            // Same photo→albedo conversion as SFPreview.ImageryGround (textures are sRGB, so c is linear).
            albedo = photoAlbedo(c);
            float rwCover = 0.0;                             // 1 on the runway's paved rectangle
            if (u.runwayB.w > 0.5 && inNear) {
                float2 rd = photoW - u.runwayA.xy, rdir = u.runwayA.zw;
                float ra = dot(rd, rdir), rc = rd.x * rdir.y - rd.y * rdir.x;      // along, right of the centreline
                float rlen = u.runwayB.x, rw = u.runwayB.y;
                float rfp = length(dwx) + length(dwy);
                rwCover = aaBand(-2.0, rlen + 2.0, ra, max(rfp, 0.05)) * aaBand(-0.5 * rw, 0.5 * rw, rc, max(rfp, 0.05));
                if (rwCover > 0.0) {
                    // Asphalt in the photo's own tone (blurred, so the photo's soft markings do not ghost under
                    // the painted ones), with aggregate grain, patching and tyre rubber in the touchdown zones.
                    float3 tone = photoAlbedo(imgNear.sample(imgSampler, nuv, level(5.0)).rgb);
                    float tl = dot(tone, float3(0.2126, 0.7152, 0.0722));
                    float3 asphalt = mix(tone, float3(tl), 0.6) * 0.92;
                    float2 rp = float2(ra, rc);
                    asphalt *= 1.0 + 0.10 * groundNoise(rp * float2(0.25, 1.0) + 13.0, 6.0) * saturate(1.0 - rfp / 12.0)
                             + 0.06 * groundNoise(photoW + 3.0, 0.35) * saturate(1.0 - rfp / 0.7);
                    float fromEnd = min(ra, rlen - ra);
                    float rubber = smoothstep(120.0, 260.0, fromEnd) * (1.0 - smoothstep(520.0, 900.0, fromEnd)) * exp(-rc * rc / 30.0);
                    asphalt *= 1.0 - 0.38 * rubber * (0.65 + 0.35 * groundNoise(rp * float2(0.05, 1.5), 1.0));
                    int low = int(u.runwayB.z + 0.5);
                    float paint = ra < 0.5 * rlen ? runwayPaint(ra, rc, rlen, rw, low, rfp)
                                                  : runwayPaint(rlen - ra, -rc, rlen, rw, low > 0 ? (low + 18 > 36 ? low - 18 : low + 18) : 0, rfp);
                    float worn = 0.78 + 0.22 * groundNoise(photoW * 0.7 + 51.0, 1.3);
                    float3 surface = mix(asphalt, float3(0.50, 0.50, 0.48) * worn, paint * (1.0 - 0.55 * rubber));
                    albedo = mix(albedo, surface, rwCover);
                }
            }
            // Canopy albedo floor (hue kept), the same 0.05 as the 3D tree tints: Sentinel-2 forest comes out
            // near-black (~0.03), so the ground between the 3D trees read as a dark smear (LSZS, rounds 4–6).
            float al = dot(albedo, float3(0.2126, 0.7152, 0.0722));
            if (imgForest > 0.0 && al < 0.07) albedo = mix(albedo, albedo * (0.07 / max(al, 0.004)), imgForest);   // 0.07 (0.05): near-black LSZS canopy under the 0.45 exposure (round 22)
            // Water: the near layer's mask (photo colour checked against land cover) inside it, the land
            // cover's water fraction carried by the outer layers beyond, blended across the near layer's edge.
            float wm = inNear ? mix(outerWater, waterMask.sample(imgSampler, nuv, level(0.0)).r, nearWeight) : outerWater;
            // Water lies flat: the coarse land-cover fraction outside the near layer bled a lake onto the steep
            // shore above it (round 26: the NZQN hillside above Lake Wakatipu rendered as smeared blue-grey
            // water and never took the slope detail). The mesh normal of a lake surface is vertical.
            wm *= smoothstep(0.93, 0.985, n.z);
            if (inNear) roadNear = waterMask.sample(imgSampler, nuv, level(0.0)).g * nearWeight;
            // Shadow toe, the mirror of the shoulder: photo shadows below ~0.10 albedo are lifted (0.03 → 0.046,
            // 0.06 → 0.072) so the baked shadows under the 3D trees and buildings, which cast their own, stop
            // reading as doubled black (art round 17, KMRY; a 0.07/0.7 toe sat below most photo shadows, round 18).
            // Fades by 1.2 km; not on water.
            // Local tone compression: each pixel held within ±40 % of the photo's ~30 m mean, so baked shadows,
            // dark car parks and bright roofs in the photo do not read as black or white blotches next to the
            // 3D scene's own lighting (art round 23: KMRY, KBFI). Near ground only; not on water or the runway.
            float ltW = (1.0 - smoothstep(900.0, 1800.0, dist)) * (1.0 - saturate((wm - 0.2) / 0.2)) * (1.0 - rwCover);
            if (ltW > 0.0) {
                float fp0 = length(dwx) + length(dwy);
                float ls = max(1.0, 30.0 / max(fp0, 1e-3));
                float2 luv; bool lin; float lw0, lw1;
                float3 lm = photoAlbedo(photoColour(u, imgNear, imgMid, imgFar, imgDetail, photoW, dwx * ls, dwy * ls, luv, lin, lw0, lw1));
                float meanL = max(dot(lm, float3(0.2126, 0.7152, 0.0722)), 0.01);
                float aL = max(dot(albedo, float3(0.2126, 0.7152, 0.0722)), 1e-4);
                float r = aL / meanL;
                // tanh's argument clamped: fast-math tanh of a large value is inf/inf = NaN, and one NaN pixel
                // bloomed into a 70 px white flare (art round 24, KMRY close).
                float rc = r < 1.0 ? 1.0 - 0.4 * tanh(min((1.0 - r) / 0.4, 8.0)) : 1.0 + 0.4 * tanh(min((r - 1.0) / 0.4, 8.0));
                float k = rc / r;
                float3 lifted = albedo * k;
                // Lifted shadows take the local mean's chroma at their new luminance: scaling RGB alone kept and
                // amplified the shadows' blue cast (round 24: saturated blue smears on the KBFI embankment).
                lifted = mix(lifted, lm * (aL * k / meanL), saturate((k - 1.1) / 0.6));
                albedo = mix(albedo, lifted, ltW);
            }
            float alT = dot(albedo, float3(0.2126, 0.7152, 0.0722));
            float toeW = (1.0 - smoothstep(400.0, 1200.0, dist)) * (1.0 - saturate((wm - 0.2) / 0.2));
            if (alT < 0.10 && toeW > 0.0) {
                float lifted = 0.10 * pow(max(alT, 1e-4) / 0.10, 0.65);
                albedo *= 1.0 + (lifted / max(alT, 1e-4) - 1.0) * toeW;
            }
            groundMat = (1.0 - smoothstep(500.0, 800.0, dist)) * (1.0 - saturate((wm - 0.2) / 0.2)) * (1.0 - rwCover);
            if (groundMat > 0.0) {
                GroundClasses k = classifyGround(c, imgForest);
                float2 tilt;
                float fpw = length(dwx) + length(dwy);
                float3 f = groundMaterial(k, in.rel.xy + u.cameraPos.xy, max(fpw, 1e-3), tilt);
                albedo *= 1.0 + (f - 1.0) * groundMat;
                groundTilt = tilt * groundMat;
            }
            if (saturate((wm - 0.35) / 0.25) > 0.5) { imageryWater = true; albedo *= 0.7; shoreWm = wm; }
            m = imageryWater ? 1.0 : 7.0;
        }
        float2 fieldW = in.rel.xy + u.cameraLocal.xy;
        float fieldFp = length(fwidth(fieldW));              // derivatives outside divergent branches
        // Footprint as the geometric mean of its two axes: on a slope seen at a grazing angle fwidth is
        // the long axis, which faded every relief octave out (round 27: the NZQN hillside beside the high
        // camera, a shaded slope smeared radially, never took the slope detail).
        float fieldFpG = sqrt(length(dfdx(fieldW)) * length(dfdy(fieldW)));
        float localFp = length(fwidth(in.local));
        float2 uvFp = float2(length(float2(dfdx(in.uv.x), dfdy(in.uv.x))), length(float2(dfdx(in.uv.y), dfdy(in.uv.y))));
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
                // Within-field variation (soil moisture, growth): ±9 % brightness at ~55 m and a ±4 % green/red
                // shift at ~35 m, so a parcel is not one flat tone (art round 19, SkyWorld phone). Outside
                // fieldFactor, which mirrors the CPU FieldPattern exactly; faded where it would alias.
                uint fs = uint(u.ambientGround.w);
                float vFade = saturate(1.0 - fieldFp * 4.0 / 35.0);
                float nB = fp_noise(fieldW.x / 55.0 + 3.1, fieldW.y / 55.0 - 1.7, fs ^ 0x3Cu);
                float nH = fp_noise(fieldW.x / 35.0 - 5.3, fieldW.y / 35.0 + 2.2, fs ^ 0xC5u);
                // Round 29: still read as flat parcels; stronger (±14 % at 55 m, ±7 % hue) plus wet/dry patches at
                // ~140 m (±12 %, slightly yellower when dry) that cross several parcels like real soil does.
                float vFadeL = saturate(1.0 - fieldFp * 4.0 / 140.0);
                float nL = fp_noise(fieldW.x / 140.0 + 11.7, fieldW.y / 140.0 - 8.9, fs ^ 0x5Au);
                f *= (1.0 + 0.14 * nB * vFade) * float3(1.0 - 0.07 * nH * vFade, 1.0 + 0.035 * nH * vFade, 1.0);
                f *= (1.0 + 0.12 * nL * vFadeL) * float3(1.0 + 0.03 * nL * vFadeL, 1.0, 1.0 - 0.05 * nL * vFadeL);
                albedo *= 1.0 + (f - 1.0) * fieldCov;
                float2 rt = fieldRowTilt(fieldW.x, fieldW.y, fieldFp, uint(u.ambientGround.w), u.skyHorizon.w > 1.5) * fieldCov;
                n = normalize(n + float3(rt, 0.0));
            }
        }
        if (m == 7.0 && in.material == 8.0 && imgForest > 0.0 && dist < 1500.0) {
            // Canopy on photo forest: crowns (4 m) and gaps (12 m), lit through a bumped normal, so
            // magnified forest reads as treetops rather than a dark green smear.
            float2 w = in.rel.xy + u.cameraPos.xy;
            float fp = fieldFp;                              // derivatives taken outside the branch
            float wc = saturate(1.0 - fp / 2.0) * imgForest * (1.0 - dist / 1500.0);
            float crown = groundNoise(w, 4.0), gap = groundNoise(w + 41.0, 12.0);
            albedo *= 1.0 + (crown * 0.30 + gap * 0.20) * wc;
            float e = 1.0;
            float gx = groundNoise(w + float2(e, 0), 4.0) - groundNoise(w - float2(e, 0), 4.0);
            float gy = groundNoise(w + float2(0, e), 4.0) - groundNoise(w - float2(0, e), 4.0);
            n = normalize(n + float3(-gx, -gy, 0.0) * (0.35 * wc));
        }
        if (m == 7.0 && dist < (in.material == 8.0 ? 900.0 : 1400.0)) {
            // Per-pixel ground detail (as SFPreview). Each octave fades out once its cell shrinks
            // below about two pixels (screen-space footprint from fwidth), so it never aliases.
            float2 w = in.rel.xy + u.cameraPos.xy;
            float fp = length(fwidth(w));
            float wFine = saturate(1.0 - fp / 1.0), wMid = saturate(1.0 - fp / 4.0), wDry = saturate(1.0 - fp / 16.0);
            float fade = (1.0 - dist / (in.material == 8.0 ? 900.0 : 1400.0)) * (1.0 - 0.7 * fieldCov) * (1.0 - groundMat);   // fields and ground materials carry their own
            float fine = groundNoise(w, 2.0), mid = groundNoise(w + 17.0, 8.0), dry = groundNoise(w - 31.0, 32.0);
            // Detail texturing over magnified photo: three octaves (0.6, 2 and 8 m) restore the grain the
            // imagery cannot resolve at the camera (KASE, round V2: a soft, smeared foreground).
            float wVF = saturate(1.0 - fp / 0.35);
            float vfine = groundNoise(w + 5.7, 0.6);
            albedo *= 1.0 + (vfine * 0.11 * wVF + fine * 0.14 * wFine + mid * 0.11 * wMid) * fade;
            albedo *= 1.0 + (float3(1.10, 1.02, 0.80) - 1.0) * (max(0.0, dry) * 0.45 * wDry * fade);
            float e = 0.6;
            float gx = groundNoise(w + float2(e, 0), 2.0) - groundNoise(w - float2(e, 0), 2.0);
            float gy = groundNoise(w + float2(0, e), 2.0) - groundNoise(w - float2(0, e), 2.0);
            n = normalize(n + float3(-gx, -gy, 0.0) * (0.12 * wFine * fade));
        }
        if (groundMat > 0.0 && !imageryWater) n = normalize(n + float3(-groundTilt, 0.0));
        if (m == 7.0 && ((in.material == 7.0 && n.z < 0.9) || (in.material == 8.0 && n.z < 0.97))) {
            // Steep ground: fall-line gullies, rock tone variation, scrub and scree (as SFPreview), each
            // octave faded by pixel footprint so big slopes keep detail far away. On the photo terrain too
            // (art round 24: NZQN and KASE hillsides were the stretched 10 m photo's smear), with the relief
            // at full strength and the tone changes at 60 % so the photo's own colours lead; no scrub or scree.
            // The photo terrain's mesh normals come from a smoothed 30 m DEM, so its steep slopes rarely fall
            // below 0.9 (round 25: the 0.9 gate never fired on the NZQN hillside or the KASE cliff).
            float steep = in.material == 8.0 ? smoothstep(0.97, 0.82, n.z) : smoothstep(0.9, 0.7, n.z);
            // No relief beside or between road ribbons (round 29: the KASE median sliver at 70 %).
            steep *= 1.0 - roadNear;
            float am = in.material == 8.0 ? 0.6 : 1.0;
            float sfp = in.material == 8.0 ? fieldFpG : fieldFp;
            // Relief on the photo terrain at 70 %: full strength tipped shaded slopes past the terminator, so
            // the strip between the KASE road's carriageways went near-black (round 26).
            float rm = in.material == 8.0 ? 0.7 : 1.0;
            float2 w = fieldW;      // true region metres (no jump at the 4 km noise wrap)
            float2 hz = n.xy; float hl = length(hz);
            float2 fall = hl > 1e-4 ? hz / hl : float2(1, 0), perp = float2(-fall.y, fall.x);
            // Triplanar on the vertical planes (horizontal axis × height), rotation-free (no wood-grain swirl).
            float wz = in.rel.z + u.cameraLocal.z;
            float ax = abs(n.x), ay = abs(n.y), asum = max(1e-3, ax + ay);
            #define TRI(ah, bv, off, dh, dz) ((ax * groundNoise(float2((w.y + (dh)) + (off) * (ah), (wz + (dz)) * (ah) / (bv)), ah) + \
                                              ay * groundNoise(float2((w.x + (dh)) - (off) * (ah), (wz + (dz)) * (ah) / (bv) - 7.0 * (ah)), ah)) / asum)
            float gw = saturate(1.0 - sfp * 2.5 / 14.0) * steep;
            if (gw > 0.0) {
                float g = TRI(14.0, 70.0, 51.0, 0.0, 0.0), gp = TRI(14.0, 70.0, 51.0, 1.5, 0.0);
                float dg = (gp - g) / 1.5 * 14.0;
                n = normalize(n + float3((perp * (-dg * 0.35 * gw)) * rm, 0.0));
                albedo *= 1.0 - 0.28 * am * max(0.0, -g) * gw;
            }
            float bw = saturate(1.0 - sfp * 2.5 / 45.0) * steep;
            if (bw > 0.0) {
                float b0 = TRI(45.0, 160.0, 91.0, 0.0, 0.0), b1 = TRI(45.0, 160.0, 91.0, 4.0, 0.0);
                float db = (b1 - b0) / 4.0 * 45.0;
                n = normalize(n + float3((perp * (-db * 0.45 * bw)) * rm, 0.0));
                float streak = TRI(9.0, 220.0, -41.0, 0.0, 0.0), ledge = TRI(320.0, 28.0, 13.0, 0.0, 0.0);
                albedo *= (1.0 - 0.22 * am * max(0.0, streak) * bw) * (1.0 + 0.12 * am * max(0.0, ledge) * bw) * (1.0 - 0.10 * am * max(0.0, -b0) * bw);
            }
            float cw = saturate(1.0 - sfp * 2.5 / 4.0) * steep;
            if (cw > 0.0) {
                float cr = TRI(4.0, 10.0, -19.0, 0.0, 0.0), crp = TRI(4.0, 10.0, -19.0, 0.5, 0.0);
                float ld = TRI(25.0, 3.5, 7.0, 0.0, 0.0), ldp = TRI(25.0, 3.5, 7.0, 0.0, 0.5);
                float dc = (crp - cr) / 0.5 * 4.0, dl = (ldp - ld) / 0.5 * 3.5;
                n = normalize(n + float3((perp * (-dc * 0.22 * cw) + fall * (dl * 0.18 * cw)) * rm, 0.0));
                albedo *= 1.0 - 0.12 * am * max(0.0, -cr) * cw;
            }
            // Photo terrain from the high camera (several metres per pixel): spurs and gully bands at ~150 m,
            // the only relief scale that survives there, as shading and a tone band down the fall line.
            float sw = (in.material == 8.0 ? 1.0 : 0.0) * saturate(1.0 - sfp * 2.5 / 150.0) * steep;
            if (sw > 0.0) {
                float s0 = TRI(150.0, 420.0, 23.0, 0.0, 0.0), s1 = TRI(150.0, 420.0, 23.0, 10.0, 0.0);
                float ds = (s1 - s0) / 10.0 * 150.0;
                n = normalize(n + float3((perp * (-ds * 0.55 * sw)) * rm, 0.0));
                albedo *= 1.0 - 0.18 * max(0.0, -s0) * sw + 0.08 * max(0.0, s0) * sw;
            }
            #undef TRI
            float big = groundNoise(w - 13.0, 64.0) * saturate(1.0 - sfp * 2.5 / 64.0);
            float small = groundNoise(w + 3.0, 8.0) * saturate(1.0 - sfp * 2.5 / 8.0);
            albedo *= 1.0 + (0.22 * big + 0.10 * small) * steep * am;
            if (in.material == 8.0) {
                // Photo slopes: scrub (darker) and scree (lighter) patches as tone changes on the photo's own
                // colour, so a soft, low-detail slope photo gains ground structure (round 29: NZQN and LSZS high).
                float patch = groundNoise(w + 71.0, 32.0) * saturate(1.0 - sfp * 2.5 / 32.0);
                float scrub = smoothstep(0.14, 0.40, patch) * steep, scree = smoothstep(-0.2, -0.45, patch) * steep;
                albedo *= (1.0 - 0.22 * scrub) * (1.0 + 0.22 * scree);
            }
            if (in.material == 7.0 && dot(albedo, float3(0.3, 0.6, 0.1)) < 0.3) {
                float patch = groundNoise(w + 71.0, 32.0) * saturate(1.0 - sfp * 2.5 / 32.0);
                float scrub = smoothstep(0.14, 0.36, patch) * steep * smoothstep(0.76, 0.84, n.z);
                float scree = smoothstep(-0.2, -0.42, patch) * steep;
                albedo = mix(albedo, float3(0.050, 0.072, 0.030), scrub * 0.75);
                albedo *= 1.0 + 0.35 * scree;
            }
        }
        float ndl = dot(n, toSun);
        float vis = toSun.z > -0.05 ? shadowVisibility(u, sm, in.rel, n, dist, max(0.0f, ndl)) : 0.0;
        float cloudShade = 0.0;                    // fraction of sunlight the cumulus removes here
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
            float ct = max(0.12, exp(-0.35 * od));  // multiple scattering keeps cloud shadows soft, never black
            vis *= ct;
            cloudShade = 1.0 - ct;
        }
        float3 ambient = mix(u.ambientGround.rgb, u.ambientSky.rgb, n.z * 0.5 + 0.5);
        // Fill light under a cumulus: the cloud's lit sides and base scatter sunlight down into its own
        // shadow, so it reads ~17 % of full sun (sky ambient alone left it at ~7 %). Sunlit ground gets none.
        ambient += u.sunColour.rgb * (0.35 * toSun.z * cloudShade);
        if (u.quality.y > 0.0) {
            // Cabin interior: lit by the sky and the sunlit ground through the windows, from every side, and
            // by direct sun on the glare shield through the windscreen. The airframe's own shadow would
            // otherwise leave the whole cabin at the ground-bounce level (near black).
            ambient = (u.ambientSky.rgb * 0.75 + u.ambientGround.rgb * 0.9 + u.sunColour.rgb * 0.035) * u.quality.y;
            float shield = smoothstep(1.10, 1.20, in.local.x) * smoothstep(0.4, 0.8, n.z);
            vis = shield * (1.0 - cloudShade);
        }
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
            // Swell: a 60 m octave on rotated axes, so the 14 m and 3.5 m wavelets no longer tile visibly
            // across a near lake (art round 12).
            float wSwell = saturate(1.0 - fieldFp * 2.5 / 60.0);
            float2 sw = float2(0.8 * ww.x - 0.6 * ww.y, 0.6 * ww.x + 0.8 * ww.y) + 123.0;
            slope += float2(groundNoise(sw + float2(2.0, 0.0), 60.0) - groundNoise(sw - float2(2.0, 0.0), 60.0),
                            groundNoise(sw + float2(0.0, 2.0), 60.0) - groundNoise(sw - float2(0.0, 2.0), 60.0)) * 0.9 * wSwell;
            // Wind: ruffled water beside calmer slicks (250 m and 1 km patches), at any distance, so a lake
            // or a bay is not one uniform sheet.
            float ruffle = 0.30 + 0.70 * smoothstep(-0.30, 0.40, groundNoise(ww + 211.0, 256.0) + 0.6 * groundNoise(ww + 97.0, 1024.0));
            slope *= 0.55 + 0.75 * ruffle;
            float3 wn = normalize(float3(-slope, 1.0));
            float3 r = reflect(dir, wn);
            r.z = abs(r.z);
            float cosT = max(0.0, -dot(dir, wn));
            float fres = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);
            // The sky the surface mirrors. Wavelets too small to resolve still tilt the facets, so far water
            // reflects sky from above the horizon line (deeper blue where it is ruffled, pale in the slicks).
            float3 rr = normalize(float3(r.xy, max(r.z, 0.02) + 0.20 * ruffle * (1.0 - 0.6 * wNear)));
            float3 skyR = skyEnv(u, rr);
            // The needle lobe only where wavelets resolve, and capped: on sub-pixel wavelets it lit single
            // pixels (fireflies that flicker in motion, art round 13).
            float glitter = min(pow(max(0.0, dot(r, toSun)), 900.0) * 60.0 * wNear, 12.0) + pow(max(0.0, dot(r, toSun)), 60.0) * 0.6;
            float3 refl = skyR + u.sunColour.rgb * glitter * vis;
            float3 body = albedo * (ambient * 0.6 + u.sunColour.rgb * max(0.0, toSun.z) * 0.15);
            // Sunlight scattered back out of the water column: the blue-green of clear water under sun.
            body += float3(0.004, 0.030, 0.042) * u.sunColour.rgb * (max(0.0, toSun.z) * 0.55 * vis);
            // Sheen toward the sun from many unresolved facets, wider where the water is ruffled.
            refl += u.sunColour.rgb * pow(max(0.0, dot(rr, toSun)), mix(260.0, 40.0, ruffle)) * (0.5 + 1.5 * ruffle) * vis;
            if (imageryWater) {
                // Shallows: a lighter green-turquoise body across the shore band (the mask's 0.6–0.9 rise), so
                // a lake edge reads as depth rather than a navy cut-out (art round 11, NZQN).
                float shallow = 1.0 - smoothstep(0.6, 0.97, shoreWm);   // wider band (round 12: read only at mid-distance)
                body = mix(body, float3(0.05, 0.11, 0.10) * (ambient * 0.8 + u.sunColour.rgb * max(0.0, toSun.z) * 0.35), shallow * 0.6);
                // Broad sheen toward the sun from many small wave facets (the 900/60 lobes are single glints).
                refl += u.sunColour.rgb * pow(max(0.0, dot(r, toSun)), 12.0) * 0.12 * vis;
            }
            float reflScale = imageryWater ? 0.85 : 1.0;         // lakes mirror most of the sky (0.6 left them navy)
            col = mix(body, refl * reflScale, min(1.0, 0.08 + fres * (imageryWater ? 0.9 : 1.0)));
            if (imageryWater) {
                // Shoreline foam: the mask's transition band (wm 0.6–0.7), broken up by noise.
                float band = 1.0 - smoothstep(0.6, 0.7, shoreWm);   // a thin line, not a white blob
                float breakUp = smoothstep(-0.1, 0.4, groundNoise(ww + 77.0, 4.0)) * wNear + 0.35 * (1.0 - wNear);
                float foam = band * breakUp * 0.18 * wNear;   // faint, and only where wavelets resolve (lakes have no surf)
                col = mix(col, float3(0.85, 0.88, 0.88) * (u.sunColour.rgb * max(0.0, toSun.z) * vis + ambient), foam);
            }
        } else if (m == 2.0) {                               // foliage: wrap + back-scatter
            float wrap = max(0.0, ndl * 0.55 + 0.45);
            float back = pow(max(0.0, dot(dir, toSun)), 4.0) * 0.35;
            // Inside a crown much of the sky is hidden by the crown itself: less (and less blue) sky light on
            // foliage, part of it replaced by light bounced from the ground below (art round 8: blue crowns).
            // Darkening on the crown's underside only (round 9: 0.7 over the whole crown dulled sunlit tops).
            float under = saturate(-n.z);
            // ×1.6: under the 0.45 exposure scale, shaded crowns on LSZS's north-facing forest went near-black
            // (art round 23); the sky light inside a real conifer stand is dim but not absent.
            float3 foliageAmb = mix(ambient, u.ambientGround.rgb, 0.25 + 0.25 * under) * (0.85 - 0.25 * under) * 1.6;
            // Leaf clumps: tone breaks up the crown at close range; the crown's own sky visibility (vertex
            // shade) darkens its inside and underside, so a tree reads as a mass of lobes, not one blob.
            float2 lw = in.rel.xy + u.cameraPos.xy;
            float clump = groundNoise(lw + in.rel.z * float2(0.43, -0.71) + 31.0, 0.7);
            float fine = groundNoise(lw - in.rel.z * float2(0.29, 0.52) - 7.0, 0.22);
            float nearT = saturate(1.0 - dist / 260.0);
            float tone = 1.0 + nearT * (0.30 * clump + 0.18 * fine);      // noise is −1…1
            float occ = mix(0.5, 1.0, saturate(in.field));   // 0.5 (0.35): see foliageAmb
            col = albedo * tone * (u.sunColour.rgb * (wrap + back) * mix(1.0, occ, 0.5) * vis + foliageAmb * occ);
        } else if (m == 10.0 || m == 11.0 || m == 12.0) {    // SF-1 airframe: painted skin, glazing, bright metal
            float3 L = in.local;
            float3 v = -dir;
            float nv = max(1e-4, dot(n, v));
            // Body-axes normal (the model matrix is a rotation): undersides see the ground, not the sky.
            float3 nb = float3(dot(n, u.model[0].xyz), dot(n, u.model[1].xyz), dot(n, u.model[2].xyz));
            float3 r = reflect(dir, n);
            float3 env = skyEnv(u, r);
            if (m == 12.0) {
                float F = 0.75 + 0.25 * pow(1.0 - nv, 5.0);
                col = albedo * (env * F + u.sunColour.rgb * ggxLobe(n, v, toSun, 0.28, 0.9) * vis) + albedo * ambient * 0.12;
            } else {
                Skin sk;
                if (m == 10.0) { sk = fuselageSkin(L, localFp); } else { sk = surfaceSkin(L, localFp); }
                if (m == 10.0 && dist < 200.0) sk.albedo = mix(sk.albedo, skinNavy, registrationMark(L, localFp) * (1.0 - sk.glass));
                // Occlusion where the airframe hides the sky from itself: cabin sides under the wing, the
                // belly, and the wing's underside at the root.
                float ao = 1.0;
                if (m == 10.0) {
                    ao -= 0.30 * smoothstep(-0.50, -0.98, L.z) * smoothstep(-1.75, -1.25, L.x) * smoothstep(0.75, 0.35, L.x);
                    ao -= 0.22 * smoothstep(0.0, 0.33, L.z);
                } else {
                    ao -= 0.25 * saturate(nb.z) * smoothstep(1.6, 0.56, abs(L.y)) * (L.z < -0.9 ? 1.0 : 0.0);
                }
                // Paint under a clear coat: diffuse base, a tight sun highlight and the sky mirrored at grazing
                // angles. White is held near 0.58 so its form shading survives the tone map's shoulder.
                float3 base = sk.albedo * 0.72;
                float F = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
                float coat = 1.0 - sk.matte;
                float3 paint = base * (u.sunColour.rgb * max(0.0, ndl) * vis + ambient * ao) * (1.0 - 0.5 * F * coat)
                             + (u.sunColour.rgb * ggxLobe(n, v, toSun, 0.16, 0.04) * vis + env * F * ao * 0.9) * coat;
                float Fg = 0.07 + 0.93 * pow(1.0 - nv, 5.0);
                float3 glass = float3(0.010, 0.014, 0.018) * (ambient + u.sunColour.rgb * max(0.0, ndl) * vis * 0.4) * (1.0 - Fg)
                             + env * Fg + u.sunColour.rgb * ggxLobe(n, v, toSun, 0.06, 0.07) * vis;
                col = mix(paint, glass, sk.glass) + sk.emissive * 0.9;
            }
        } else if (m == 14.0) {                              // building wall: storeys, window bays, cladding
            Facade fc = facade(in.uv, in.style, albedo, max(uvFp.x, 1e-4), max(uvFp.y, 1e-4));
            float3 v = -dir;
            float nv = max(1e-4, dot(n, v));
            float3 r = reflect(dir, n);
            // Streets hide the low sky: near-horizontal reflections take a city tone, not the bright horizon.
            float3 env = mix(u.ambientGround.rgb * 1.8, skyEnv(u, r), smoothstep(0.02, 0.35, r.z));
            float F = fc.f0 + (1.0 - fc.f0) * pow(1.0 - nv, 5.0);
            float aoW = mix(0.55, 1.0, saturate(in.uv.y / max(in.style.w, 1.0) * 1.5 + 0.2));    // less sky toward the street
            float3 wallCol = fc.albedo * (u.sunColour.rgb * max(0.0, ndl) * vis + ambient * aoW);
            float3 glassCol = fc.interior * (u.sunColour.rgb * max(0.0, ndl) * vis * 0.6 + ambient * aoW) * (1.0 - F)
                            + env * fc.tint * F + u.sunColour.rgb * ggxLobe(n, v, toSun, 0.10, fc.f0) * vis;
            col = mix(wallCol, glassCol, fc.glass);
        } else if (m == 15.0) {                              // roof: one colour per building (from the photo at load) with roofing mottle
            float3 a = albedo;
            if (fmod(in.style.z, 2.0) > 0.5) {
                float2 ruv; bool rin;
                float rw0, rw1;
                // The roof's tone, not the photo projected onto it: sampled ~4 mips coarser (≈ 13 m at the US
                // 1.6 m source), so the photo's skylights, cars and the roof's own baked shadow do not show as
                // blotches on the 3D roof (art round 22, KBFI), and clamped to real roofing albedo.
                a = photoAlbedo(photoColour(u, imgNear, imgMid, imgFar, imgDetail, photoW, dwx * 12.0, dwy * 12.0, ruv, rin, rw0, rw1));
                float al = dot(a, float3(0.2126, 0.7152, 0.0722));
                if (al > 0.32) a *= 0.32 / al;
            }
            float2 rw = in.rel.xy + u.cameraPos.xy;
            float fpw = length(dwx) + length(dwy);
            a *= 1.0 + 0.10 * groundNoise(rw, 1.5) * saturate(1.0 - fpw / 0.75) + 0.08 * groundNoise(rw + 19.0, 9.0) * saturate(1.0 - fpw / 4.5)
                   + 0.05 * groundNoise(rw * float2(1.0, 0.15) + 41.0, 4.0) * saturate(1.0 - fpw / 2.0);   // weathering streaks
            col = a * (u.sunColour.rgb * max(0.0, ndl) * vis + ambient);
        } else if (m == 6.0 || m == 5.0) {                   // aircraft paint / glass: GGX
            // Panel seams on the airframe (aircraft-sized local coordinates only, not painted scenery).
            // White paint at ~0.66 albedo sat at the tone-map shoulder in midday sun, so the airframe read as a
            // flat white ribbon (art rounds 7–8; 0.52 still rendered ~245/255); 0.40 keeps it white while its form shading shows.
            if (m == 6.0) albedo = min(albedo, float3(0.40));
            // Livery seen from the chase camera (above and behind): fin, tailplane tips and a stripe down the
            // fuselage top in the accent blue, so the airframe is not one white silhouette (art round 10).
            if (m == 6.0 && length(in.local) < 9.0) {
                float3 L = in.local;
                float lv = 0.0;
                if (L.x < -3.4 && abs(L.y) < 0.12 && L.z < -0.8) lv = 1.0;                                 // fin
                if (L.x < -3.4 && abs(L.y) > 1.05 && L.z > -0.9 && L.z < -0.4) lv = 1.0;                   // tailplane tips
                if (L.x > -3.6 && L.x < 1.8 && L.z < -0.9 && abs(L.y) < 0.75)                              // fuselage-top stripe
                    lv = max(lv, 1.0 - smoothstep(0.07, 0.07 + max(localFp, 0.005), abs(L.y)));
                albedo = mix(albedo, float3(0.012, 0.05, 0.19), lv);
            }
            if (m == 6.0 && length(in.local) < 9.0 && dist < 150.0) {
                // Seams stay subtle (they read as dashed road markings at 0.45 on the chase view, round 7).
                albedo *= 1.0 - 0.22 * aircraftPanels(in.local, localFp);
                albedo = mix(albedo, float3(0.012, 0.014, 0.022), registrationMark(in.local, localFp));
            }
            float rough = m == 6.0 ? 0.24 : 0.06;   // glossy paint: a visible sun glint
            float3 env = mix(u.ambientGround.rgb, u.skyHorizon.rgb, saturate(reflect(dir, n).z * 0.5 + 0.5));
            // Contact occlusion where surfaces meet (wing and tailplane roots, under the wing at the cabin), so
            // the white airframe has shaded junctions instead of one flat tone (art round 6).
            float ao = 1.0;
            if (m == 6.0 && length(in.local) < 9.0) {
                float3 L = in.local;
                float root = max(0.0, abs(L.y) - 0.55);
                if (L.z < -0.9 && abs(L.y) >= 0.5) ao -= 0.30 * exp(-root / 0.35);               // wing root
                if (L.x < -3.6 && abs(L.y) >= 0.15 && L.z > -0.9) ao -= 0.25 * exp(-max(0.0, abs(L.y) - 0.15) / 0.25);   // tailplane root
                if (abs(L.y) < 0.75 && L.z > -0.95 && L.z < -0.75 && L.x > -1.6 && L.x < 0.4) ao -= 0.20 * smoothstep(-0.75, -0.95, L.z);   // cabin under the wing
                // Fuselage lower curve (body z down): the belly sees ground, not sky (round 9: flat sides).
                if (abs(L.y) < 0.75 && L.z > -0.95) ao -= 0.15 * smoothstep(-0.3, 0.3, L.z);
            }
            col = pbrDielectric(albedo, n, -dir, toSun, rough, u.sunColour.rgb, env, vis) * mix(1.0, ao, 0.5)
                + albedo * ambient * (m == 6.0 ? 1.0 : 0.3) * ao;
        } else {
            col = albedo * (u.sunColour.rgb * max(0.0, ndl) * vis + ambient);
            if (m == 3.0) {                      // road: asphalt grain, painted lines, Blinn-Phong highlight
                // The field channel is the position across the carriageway (−1 left edge … +1 right edge) on
                // roads that carry a centre line and 0 everywhere on those that do not (OSMMeshBuilder.roads),
                // so a line is painted where it crosses zero with a slope.
                float fa = abs(in.field), fw = fwidth(in.field);
                float2 rw = in.rel.xy + u.cameraPos.xy;
                float rfp = length(fwidth(rw));
                float3 road = albedo * (1.0 + 0.10 * groundNoise(rw + 9.0, 0.5) * saturate(1.0 - rfp / 1.0)
                                            + 0.08 * groundNoise(rw - 33.0, 7.0) * saturate(1.0 - rfp / 14.0));
                // Sit in the photo: a quarter of the photo's own (blurred) tone everywhere, more toward the
                // carriageway edges, so the ribbon is not a dark overlay on the photo's road (art round 22, KASE).
                {
                    float2 pr; bool pin; float p0, p1;
                    float3 under = photoAlbedo(photoColour(u, imgNear, imgMid, imgFar, imgDetail, photoW, dwx * 2.0, dwy * 2.0, pr, pin, p0, p1));
                    float edge = smoothstep(0.7, 1.0, fa) * step(1e-4, fw);
                    road = mix(road, under, 0.25 + 0.55 * edge);
                }
                float lines = (1.0 - smoothstep(0.0, 0.03 + fw, fa)) * step(1e-4, fw) * saturate(1.3 - fw * 6.0);
                float3 paint = float3(0.46, 0.45, 0.42);
                col = mix(road, paint, lines * 0.85) * (u.sunColour.rgb * max(0.0, ndl) * vis + ambient);
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
        // A motion-blurred disc: faint, denser toward the tips, fading out at the rim (no hard edge), with
        // the residual two-blade strobing a camera records and the painted tips as a thin soft band.
        float rim = 1.0 - smoothstep(0.93, 1.0, r);
        float strobe = 0.72 + 0.28 * cos(2.0 * th + u.skyZenith.w * 37.0);
        float alpha = (0.045 + 0.085 * smoothstep(0.15, 0.9, r)) * strobe * rim;
        float3 base = float3(0.02, 0.02, 0.022);
        float tip = smoothstep(0.895, 0.92, r) * (1.0 - smoothstep(0.95, 0.975, r));
        base = mix(base, float3(0.55, 0.45, 0.08), tip);
        alpha = mix(alpha, 0.10 * strobe, tip);
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
