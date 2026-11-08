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
