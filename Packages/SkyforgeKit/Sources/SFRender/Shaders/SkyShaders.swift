// SKYFORGE — Apache-2.0
// MSL kept as a Swift string and compiled at runtime (no .metal files; see docs/DECISIONS.md ADR-0003).

public enum SkyShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SkyVarying {
        float4 position [[position]];
        float2 uv;
    };

    struct SkyUniforms {
        float3 sunDirection;   // view space, normalised
        float  time;
        float3 zenithColor;
        float  exposure;
        float3 horizonColor;
        float  aspect;
    };

    vertex SkyVarying sky_vertex(uint vid [[vertex_id]]) {
        // Fullscreen triangle
        float2 p = float2((vid << 1) & 2, vid & 2);
        SkyVarying out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    static float3 aces(float3 x) {
        const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
        return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    fragment float4 sky_fragment(SkyVarying in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
        float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
        float3 dir = normalize(float3(ndc.x * u.aspect, ndc.y * 0.75 + 0.15, -1.0));
        float h = saturate(dir.y);
        float3 sky = mix(u.horizonColor, u.zenithColor, pow(h, 0.45));
        float sunDot = saturate(dot(dir, normalize(u.sunDirection)));
        sky += float3(1.0, 0.75, 0.45) * (pow(sunDot, 600.0) * 20.0 + pow(sunDot, 8.0) * 0.35);
        if (dir.y < 0.0) {
            sky = mix(u.horizonColor * 0.55, float3(0.18, 0.20, 0.16), saturate(-dir.y * 3.0));
        }
        float3 color = aces(sky * u.exposure);
        return float4(pow(color, float3(1.0 / 2.2)), 1.0);
    }
    """
}
