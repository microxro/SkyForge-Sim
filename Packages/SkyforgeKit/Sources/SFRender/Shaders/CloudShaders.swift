// SKYFORGE — Apache-2.0
// Volumetric cumulus pass. A line-by-line port of SFAtmosphere.VolumetricClouds (the CPU reference);
// CI compares `cloud_march_rays` against it. The march runs at half resolution into an RGBA16F
// buffer (premultiplied tone-mapped mean cloud colour, coverage alpha), then `cloud_composite` upsamples and blends
// it over the frame.

public enum CloudShaders {
    /// Layer struct, hash/value noise and density (shared with the world pass for cloud shadows).
    public static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct CloudLayerGPU { float4 shape; float4 drift; };   // base, thickness, coverage, extinction | offset.xy

    struct CloudUniforms {
        float4 camPos;      // xyz local metres, w = march steps
        float4 forward;     // w = near plane (reversed-Z)
        float4 right;       // w = tan(hfov/2)
        float4 up;          // w = tan(vfov/2)
        float4 toSun;       // w = sun azimuth (rad)
        float4 sun;         // rgb sun colour, w = exposure
        float4 skyAmb;      // rgb, w = aerial table max distance (km)
        float4 groundAmb;   // rgb, w = 1 when aerial tables are valid
        float4 tableDims;   // nD, nAz, nEl, unused
        float4 viewport;    // march width, height, full width, full height
        CloudLayerGPU layer;
    };

    static float cl_hash(int x, int y, int z) {
        uint h = uint(x) * 0x8DA6B343u;
        h ^= uint(y) * 0xD8163841u;
        h ^= uint(z) * 0xCB1AB31Fu;
        h ^= h >> 13;
        h *= 0x5BD1E995u;
        h ^= h >> 15;
        return float(h & 0x00FFFFFFu) / 16777216.0;
    }

    static float cl_fade(float t) { return t * t * (3.0 - 2.0 * t); }

    static float cl_noise(float3 p) {
        float3 f = floor(p);
        int ix = int(f.x), iy = int(f.y), iz = int(f.z);
        float tx = cl_fade(p.x - f.x), ty = cl_fade(p.y - f.y), tz = cl_fade(p.z - f.z);
        float c000 = cl_hash(ix, iy, iz), c100 = cl_hash(ix + 1, iy, iz);
        float c010 = cl_hash(ix, iy + 1, iz), c110 = cl_hash(ix + 1, iy + 1, iz);
        float c001 = cl_hash(ix, iy, iz + 1), c101 = cl_hash(ix + 1, iy, iz + 1);
        float c011 = cl_hash(ix, iy + 1, iz + 1), c111 = cl_hash(ix + 1, iy + 1, iz + 1);
        float a = mix(mix(c000, c100, tx), mix(c010, c110, tx), ty);
        float b = mix(mix(c001, c101, tx), mix(c011, c111, tx), ty);
        return mix(a, b, tz);
    }

    static float cl_smooth(float e0, float e1, float x) {
        float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    static float cl_density(float3 p, CloudLayerGPU c) {
        float base = c.shape.x, thick = c.shape.y, cover = c.shape.z, ext = c.shape.w;
        float h = (p.z - base) / thick;
        if (h <= 0.0 || h >= 1.0 || cover <= 0.0) return 0.0;
        float qx = p.x + c.drift.x, qy = p.y + c.drift.y;
        float cov = 0.65 * cl_noise(float3(qx / 2600.0, qy / 2600.0, 0.5)) + 0.35 * cl_noise(float3(qx / 900.0, qy / 900.0, 17.5));
        float s = (cov - (1.0 - cover)) / max(cover, 0.05);
        s = s * cl_smooth(0.0, 0.12, h) - 0.55 * h * h;
        if (s <= 0.0) return 0.0;
        float detail = 0.625 * cl_noise(float3(qx, qy, p.z) / 220.0) + 0.375 * cl_noise(float3(qx, qy, p.z * 1.3) / 90.0);
        float d = s - (1.0 - detail) * 0.22;
        if (d <= 0.0) return 0.0;
        return min(1.0, d * 2.2) * ext;
    }

    """

    public static let source = common + """
    static float cl_hg(float cosT, float g) {
        float g2 = g * g;
        float denom = max(1e-4, 1.0 + g2 - 2.0 * g * cosT);
        return (1.0 - g2) / (4.0 * M_PI_F * denom * sqrt(denom));
    }

    static float cl_phase(float cosT) { return 0.7 * cl_hg(cosT, 0.6) + 0.3 * cl_hg(cosT, -0.25); }

    static float cl_lightDepth(float3 p, float3 toSun, CloudLayerGPU c) {
        float od = 0.0, t = 0.0, step = 40.0;
        for (int i = 0; i < 6; i++) {
            float3 q = p + toSun * (t + 0.5 * step);
            od += cl_density(q, c) * step;
            t += step; step *= 1.8;
        }
        return od;
    }

    struct CloudResult { float3 L; float T; float depth; };

    static CloudResult cl_march(float3 o, float3 d, float maxDist, CloudLayerGPU c, float3 toSun, float3 sun,
                                float3 skyAmb, float3 groundAmb, int steps, float jitter) {
        CloudResult r; r.L = float3(0.0); r.T = 1.0; r.depth = 0.0;
        float base = c.shape.x, top = c.shape.x + c.shape.y;
        if (c.shape.z <= 0.0) return r;
        float t0 = 0.0, t1 = min(maxDist, 24000.0);
        if (abs(d.z) < 1e-5) {
            if (o.z <= base || o.z >= top) return r;
        } else {
            float ta = (base - o.z) / d.z, tb = (top - o.z) / d.z;
            t0 = max(t0, min(ta, tb)); t1 = min(t1, max(ta, tb));
        }
        if (t1 <= t0) return r;
        float dt = (t1 - t0) / float(steps);
        float ph = cl_phase(dot(d, toSun)) * 4.0 * M_PI_F;
        float T = 1.0, depthSum = 0.0, wSum = 0.0;
        float3 L = float3(0.0);
        for (int i = 0; i < steps; i++) {
            float t = t0 + (float(i) + jitter) * dt;
            float3 p = o + d * t;
            float sigma = cl_density(p, c);
            if (sigma <= 0.0) continue;
            float od = cl_lightDepth(p, toSun, c);
            float h = (p.z - c.shape.x) / c.shape.y;
            float3 direct = sun * (ph * exp(-od) + 0.6 * exp(-0.25 * od));
            float powder = 1.0 - 0.6 * exp(-sigma * 120.0);
            float3 amb = skyAmb * (0.35 + 0.65 * h) + groundAmb * (0.35 * (1.0 - h));
            float3 S = (direct * powder + amb) * sigma;
            float Ts = exp(-sigma * dt);
            float3 integ = (S - S * Ts) / sigma;
            L += T * integ;
            float w = T * (1.0 - Ts);
            depthSum += w * t; wSum += w;
            T *= Ts;
            if (T < 0.01) break;
        }
        r.L = L; r.T = T; r.depth = wSum > 0.0 ? depthSum / wSum : 0.0;
        return r;
    }

    static float cl_jitter(uint x, uint y) {
        float v = 52.982918 * fract(0.06711056 * float(x) + 0.00583715 * float(y));
        return fract(v);
    }

    // Test kernel: one ray per thread, same inputs as VolumetricClouds.march.
    struct CloudRay { float4 origin; float4 dir; };   // origin.w = maxDist, dir.w = jitter
    kernel void cloud_march_rays(device const CloudRay* rays [[buffer(0)]], device float4* out [[buffer(1)]],
                                 constant CloudUniforms& u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        CloudRay ray = rays[i];
        CloudResult r = cl_march(ray.origin.xyz, ray.dir.xyz, ray.origin.w, u.layer, u.toSun.xyz, u.sun.rgb,
                                 u.skyAmb.rgb, u.groundAmb.rgb, int(u.camPos.w), ray.dir.w);
        out[2 * i] = float4(r.L, r.T);
        out[2 * i + 1] = float4(r.depth, 0.0, 0.0, 0.0);
    }

    constexpr sampler cl_tbl(filter::linear, address::clamp_to_edge, coord::normalized);

    static void cl_aerial(constant CloudUniforms& u, texture3d<float> ins, texture3d<float> tr, float3 dir, float dist,
                          thread float3& L, thread float3& T) {
        float nD = u.tableDims.x, nAz = u.tableDims.y, nEl = u.tableDims.z;
        float el = asin(clamp(dir.z, -1.0f, 1.0f));
        float s = sqrt(abs(el) / (M_PI_F / 2.0)) * (el < 0.0 ? -1.0 : 1.0);
        float fj = clamp((s + 1.0) * 0.5, 0.0, 1.0) * (nEl - 1.0);
        float rel = atan2(dir.y, dir.x) - u.toSun.w;
        rel = abs(rel - 2.0 * M_PI_F * floor(rel / (2.0 * M_PI_F) + 0.5));
        float fi = min(nAz - 1.0, rel / M_PI_F * (nAz - 1.0));
        float w = min(1.0, sqrt(dist / 1000.0 / u.skyAmb.w));
        float fk = w * nD - 1.0;
        float3 uvw = float3((max(fk, 0.0) + 0.5) / nD, (fi + 0.5) / nAz, (fj + 0.5) / nEl);
        L = ins.sample(cl_tbl, uvw).rgb;
        T = tr.sample(cl_tbl, uvw).rgb;
        if (fk < 0.0) { float f = fk + 1.0; L *= f; T = 1.0 + (T - 1.0) * f; }
    }

    static float3 cl_aces(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    struct CloudVarying { float4 position [[position]]; float2 uv; };

    vertex CloudVarying cloud_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        CloudVarying o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // Half-resolution march. Output (premultiplied): rgb = tone-mapped mean cloud colour × a, a = coverage (1 − T).
    fragment float4 cloud_march_fragment(CloudVarying in [[stage_in]], constant CloudUniforms& u [[buffer(0)]],
                                         depth2d<float> depth [[texture(0)]],
                                         texture3d<float> ins [[texture(1)]], texture3d<float> tr [[texture(2)]]) {
        float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
        float3 dir = normalize(u.forward.xyz + u.right.xyz * (ndc.x * u.right.w) + u.up.xyz * (ndc.y * u.up.w));
        uint2 full = uint2(min(in.uv * u.viewport.zw, u.viewport.zw - 1.0));
        float z = depth.read(full);
        float maxDist = z > 0.0 ? (u.forward.w / z) / max(1e-4, dot(dir, u.forward.xyz)) : 1e9;
        uint2 px = uint2(in.position.xy);
        CloudResult r = cl_march(u.camPos.xyz, dir, maxDist, u.layer, u.toSun.xyz, u.sun.rgb, u.skyAmb.rgb, u.groundAmb.rgb,
                                 int(u.camPos.w), cl_jitter(px.x, px.y));
        float a = 1.0 - r.T;
        if (a < 0.002) return float4(0.0);
        float3 col = r.L;
        float3 La = float3(0.0), Ta = float3(1.0);
        if (u.groundAmb.w > 0.5) { cl_aerial(u, ins, tr, dir, r.depth, La, Ta); }
        col = col * Ta + La * a;
        float3 mean = col / a;
        return float4(pow(cl_aces(mean * u.sun.w), float3(1.0 / 2.2)) * a, a);   // premultiplied
    }

    constexpr sampler cl_lin(filter::linear, address::clamp_to_edge, coord::normalized);

    // Upsample with a small tent filter: hides the per-pixel jitter pattern of the half-res march
    // (art review: visible dither on cloud bodies) without smearing cloud edges.
    fragment float4 cloud_composite_fragment(CloudVarying in [[stage_in]], texture2d<float> clouds [[texture(0)]]) {
        float2 t = 1.0 / float2(clouds.get_width(), clouds.get_height());
        float4 c = clouds.sample(cl_lin, in.uv) * 0.36;
        c += clouds.sample(cl_lin, in.uv + float2( 0.9,  0.9) * t) * 0.16;
        c += clouds.sample(cl_lin, in.uv + float2(-0.9,  0.9) * t) * 0.16;
        c += clouds.sample(cl_lin, in.uv + float2( 0.9, -0.9) * t) * 0.16;
        c += clouds.sample(cl_lin, in.uv + float2(-0.9, -0.9) * t) * 0.16;
        return c;
    }
    """
}
