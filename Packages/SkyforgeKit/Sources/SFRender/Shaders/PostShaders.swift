// SKYFORGE — Apache-2.0
// Post-processing: FXAA (after T. Lottes, "FXAA", NVIDIA 2009/2011; the classic 4-tap edge
// direction + 2/4-tap blend variant). Runs on the final tone-mapped, gamma-encoded frame.

public enum PostShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct PostVarying { float4 position [[position]]; float2 uv; };

    vertex PostVarying post_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        PostVarying o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    constexpr sampler fx(filter::linear, address::clamp_to_edge, coord::normalized);
    constexpr sampler fxd(filter::nearest, address::clamp_to_edge, coord::normalized);

    // MARK: Bloom (after Jimenez, "Next Generation Post Processing in Call of Duty: Advanced Warfare",
    // SIGGRAPH 2014): 13-tap downsample with a soft-knee prefilter, 3×3 tent upsample, and an
    // energy-conserving composite (the scene is lerped toward its blurred self, never added to).

    struct BloomParams { float4 p; };   // threshold, knee, intensity, 1 = first (prefilter) level

    static float3 bl_prefilter(float3 c, float threshold, float knee) {
        float br = max(c.r, max(c.g, c.b));
        float rq = clamp(br - threshold + knee, 0.0, 2.0 * knee);
        rq = rq * rq / (4.0 * knee + 1e-5);
        float w = max(rq, br - threshold) / max(br, 1e-5);
        return c * w;
    }

    static float3 bl_tap(texture2d<float> t, float2 uv) { return min(t.sample(fx, uv).rgb, float3(6.0e4)); }

    fragment float4 bloom_down_fragment(PostVarying in [[stage_in]], texture2d<float> t [[texture(0)]],
                                        constant BloomParams& bp [[buffer(0)]]) {
        float2 d = 1.0 / float2(t.get_width(), t.get_height());
        float2 uv = in.uv;
        float3 a = bl_tap(t, uv + d * float2(-2, -2)), b = bl_tap(t, uv + d * float2(0, -2)), c = bl_tap(t, uv + d * float2(2, -2));
        float3 e = bl_tap(t, uv + d * float2(-2, 0)), f = bl_tap(t, uv), g = bl_tap(t, uv + d * float2(2, 0));
        float3 h = bl_tap(t, uv + d * float2(-2, 2)), i = bl_tap(t, uv + d * float2(0, 2)), j = bl_tap(t, uv + d * float2(2, 2));
        float3 k = bl_tap(t, uv + d * float2(-1, -1)), l = bl_tap(t, uv + d * float2(1, -1));
        float3 m = bl_tap(t, uv + d * float2(-1, 1)), n = bl_tap(t, uv + d * float2(1, 1));
        float3 o = (k + l + m + n) * 0.125 + f * 0.125 + (a + c + h + j) * 0.03125 + (b + e + g + i) * 0.0625;
        if (bp.p.w > 0.5) o = bl_prefilter(o, bp.p.x, bp.p.y);
        return float4(o, 1.0);
    }

    fragment float4 bloom_up_fragment(PostVarying in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        float2 d = 1.0 / float2(t.get_width(), t.get_height());
        float2 uv = in.uv;
        float3 s = t.sample(fx, uv).rgb * 4.0;
        s += (t.sample(fx, uv + float2(-d.x, 0)).rgb + t.sample(fx, uv + float2(d.x, 0)).rgb
            + t.sample(fx, uv + float2(0, -d.y)).rgb + t.sample(fx, uv + float2(0, d.y)).rgb) * 2.0;
        s += t.sample(fx, uv + float2(-d.x, -d.y)).rgb + t.sample(fx, uv + float2(d.x, -d.y)).rgb
           + t.sample(fx, uv + float2(-d.x, d.y)).rgb + t.sample(fx, uv + float2(d.x, d.y)).rgb;
        return float4(s / 16.0, 1.0);   // blended additively onto the next larger level
    }

    // MARK: Screen-space ambient occlusion (depth only; after McGuire et al., "The Alchemy Screen-Space
    // Ambient Obscurance Algorithm", HPG 2011). Reversed infinite-Z: view distance = near / depth.
    struct AOParams { float4 p; };   // near, tan(half fov x), tan(half fov y), radius (m)

    static float3 ao_view(float2 uv, float z, float4 p) {
        float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
        return float3(ndc.x * p.y * z, ndc.y * p.z * z, z);
    }

    fragment float4 ssao_fragment(PostVarying in [[stage_in]], depth2d<float> depth [[texture(0)]],
                                  constant AOParams& ap [[buffer(0)]]) {
        uint2 size = uint2(depth.get_width(), depth.get_height());
        uint2 px = uint2(min(in.position.xy, float2(size) - 1.0));
        float d = depth.read(px);
        if (d <= 0.0) return float4(1.0);                        // sky
        float4 p = ap.p;
        float z = p.x / d;
        float3 P = ao_view(in.uv, z, p);
        float3 N = normalize(cross(dfdx(P), dfdy(P)));
        if (N.z > 0.0) N = -N;                                    // face the camera (camera looks along +z here)
        float radius = p.w;
        float rPx = radius / (z * p.z) * float(size.y) * 0.5;    // radius in pixels
        if (rPx < 1.0) return float4(1.0);
        rPx = min(rPx, 64.0);
        float ang = 6.2831853 * fract(52.982919 * fract(dot(in.position.xy, float2(0.06711056, 0.00583715))));
        float occ = 0.0;
        const int K = 10;
        for (int k = 0; k < K; k++) {
            float t = (float(k) + 0.5) / float(K);
            float a = ang + float(k) * 2.39996323;               // golden-angle spiral
            float2 off = float2(cos(a), sin(a)) * rPx * t;
            int2 q = int2(float2(px) + off);
            if (q.x < 0 || q.y < 0 || q.x >= int(size.x) || q.y >= int(size.y)) continue;
            float dq = depth.read(uint2(q));
            if (dq <= 0.0) continue;
            float zq = p.x / dq;
            float3 Q = ao_view((float2(q) + 0.5) / float2(size), zq, p);
            float3 v = Q - P;
            float vv = dot(v, v);
            float fall = saturate(1.0 - vv / (radius * radius * 4.0));
            occ += max(0.0, dot(v, N) - 0.02 * z) / (vv + 0.01) * fall;
        }
        float ao = saturate(1.0 - 2.0 * 0.6 * occ / float(K));
        return float4(ao, ao, ao, 1.0);
    }

    static float3 post_aces(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    /// HDR scene (+ bloom) → ACES → gamma 2.2. Bloom levels were summed, so normalise by their count.
    fragment float4 tonemap_fragment(PostVarying in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                     texture2d<float> bloom [[texture(1)]], texture2d<float> ao [[texture(2)]],
                                     constant BloomParams& bp [[buffer(0)]], constant float4& aoStrength [[buffer(1)]]) {
        float3 c = scene.sample(fx, in.uv).rgb;
        if (aoStrength.x > 0.0) {
            // 4-tap blur of the AO term, then darken (contact shadows under buildings, trees, the aircraft).
            float2 t = 1.0 / float2(ao.get_width(), ao.get_height());
            float a = 0.25 * (ao.sample(fx, in.uv + t * float2(-0.75, -0.25)).r + ao.sample(fx, in.uv + t * float2(0.75, 0.25)).r
                            + ao.sample(fx, in.uv + t * float2(-0.25, 0.75)).r + ao.sample(fx, in.uv + t * float2(0.25, -0.75)).r);
            c *= mix(1.0, a, aoStrength.x);
        }
        if (bp.p.z > 0.0) {
            float3 b = bloom.sample(fx, in.uv).rgb * bp.p.w;    // p.w = 1 / number of summed levels
            c = mix(c, b, bp.p.z);
        }
        float3 g = pow(post_aces(max(c, 0.0)), float3(1.0 / 2.2));
        float k = aoStrength.y;                                  // colour grade strength (0 = off)
        if (k > 0.0) {
            // Gentle filmic contrast: cubic S around mid-grey, faded out below ~0.25 so shadows keep their
            // detail (no crushed toe), then vibrance that spares already-saturated colours.
            float3 s = g + 0.30 * g * (1.0 - g) * (2.0 * g - 1.0) * smoothstep(0.06, 0.25, g);
            float l = dot(s, float3(0.2126, 0.7152, 0.0722));
            float sat = max(s.r, max(s.g, s.b)) - min(s.r, min(s.g, s.b));
            // Greens get none: grass and crops already sit near the saturation the eye accepts (SkyWorld
            // fields turned lime with it).
            float greenness = saturate((s.g - max(s.r, s.b)) * 8.0);
            s = l + (s - l) * (1.0 + 0.10 * saturate(1.0 - 2.5 * sat) * (1.0 - greenness));
            g = mix(g, saturate(s), k);
        }
        return float4(g, 1.0);
    }

    static float fx_luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

    // Depth-aware: only geometric edges (silhouettes, building and tree outlines) are antialiased.
    // Plain FXAA treated photo texture as edges everywhere and smeared the ground imagery along the
    // detected directions by up to 8 px.
    fragment float4 fxaa_fragment(PostVarying in [[stage_in]], texture2d<float> t [[texture(0)]],
                                  depth2d<float> depth [[texture(1)]]) {
        const float reduceMin = 1.0 / 128.0, reduceMul = 1.0 / 8.0, spanMax = 4.0;
        float2 rcp = 1.0 / float2(t.get_width(), t.get_height());
        float2 uv = in.uv;
        float3 rgbM = t.sample(fx, uv).rgb;
        float2 drcp = 1.0 / float2(depth.get_width(), depth.get_height());
        float d0 = depth.sample(fxd, uv), d1 = depth.sample(fxd, uv + float2(-1.0, -1.0) * drcp), d2 = depth.sample(fxd, uv + float2(1.0, -1.0) * drcp);
        float d3 = depth.sample(fxd, uv + float2(-1.0, 1.0) * drcp), d4 = depth.sample(fxd, uv + float2(1.0, 1.0) * drcp);
        float dMin = min(d0, min(min(d1, d2), min(d3, d4))), dMax = max(d0, max(max(d1, d2), max(d3, d4)));
        // Reversed-Z depth ∝ 1/distance, so the ratio is scale-free; sky is 0.
        bool geomEdge = (dMin <= 0.0 && dMax > 0.0) || (dMin > 0.0 && dMax > dMin * 1.04);
        if (!geomEdge) return float4(rgbM, 1.0);
        float3 rgbNW = t.sample(fx, uv + float2(-1.0, -1.0) * rcp).rgb;
        float3 rgbNE = t.sample(fx, uv + float2( 1.0, -1.0) * rcp).rgb;
        float3 rgbSW = t.sample(fx, uv + float2(-1.0,  1.0) * rcp).rgb;
        float3 rgbSE = t.sample(fx, uv + float2( 1.0,  1.0) * rcp).rgb;
        float lM = fx_luma(rgbM), lNW = fx_luma(rgbNW), lNE = fx_luma(rgbNE), lSW = fx_luma(rgbSW), lSE = fx_luma(rgbSE);
        float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
        float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
        if (lMax - lMin < max(0.0312, lMax * 0.125)) return float4(rgbM, 1.0);   // no edge
        float2 dir = float2(-((lNW + lNE) - (lSW + lSE)), (lNW + lSW) - (lNE + lSE));
        float dirReduce = max((lNW + lNE + lSW + lSE) * 0.25 * reduceMul, reduceMin);
        float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
        dir = clamp(dir * rcpDirMin, -spanMax, spanMax) * rcp;
        float3 rgbA = 0.5 * (t.sample(fx, uv + dir * (1.0 / 3.0 - 0.5)).rgb + t.sample(fx, uv + dir * (2.0 / 3.0 - 0.5)).rgb);
        float3 rgbB = rgbA * 0.5 + 0.25 * (t.sample(fx, uv - dir * 0.5).rgb + t.sample(fx, uv + dir * 0.5).rgb);
        float lB = fx_luma(rgbB);
        return float4((lB < lMin || lB > lMax) ? rgbA : rgbB, 1.0);
    }
    """
}
