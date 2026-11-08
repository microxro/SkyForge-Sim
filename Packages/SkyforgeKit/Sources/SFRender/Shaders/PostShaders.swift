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

    static float3 post_aces(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    /// HDR scene (+ bloom) → ACES → gamma 2.2. Bloom levels were summed, so normalise by their count.
    fragment float4 tonemap_fragment(PostVarying in [[stage_in]], texture2d<float> scene [[texture(0)]],
                                     texture2d<float> bloom [[texture(1)]], constant BloomParams& bp [[buffer(0)]]) {
        float3 c = scene.sample(fx, in.uv).rgb;
        if (bp.p.z > 0.0) {
            float3 b = bloom.sample(fx, in.uv).rgb * bp.p.w;    // p.w = 1 / number of summed levels
            c = mix(c, b, bp.p.z);
        }
        return float4(pow(post_aces(max(c, 0.0)), float3(1.0 / 2.2)), 1.0);
    }

    static float fx_luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

    fragment float4 fxaa_fragment(PostVarying in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        const float reduceMin = 1.0 / 128.0, reduceMul = 1.0 / 8.0, spanMax = 8.0;
        float2 rcp = 1.0 / float2(t.get_width(), t.get_height());
        float2 uv = in.uv;
        float3 rgbM = t.sample(fx, uv).rgb;
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
