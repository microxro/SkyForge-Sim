// SKYFORGE — Apache-2.0
// MSL for aircraft exterior detail (round 5). Helper functions are `ax_`-prefixed so they can be appended to
// the world library without clashing; mirrors `AircraftExterior.swift`. Integration: docs/rounds/ROUND5_aircraft.md.

public enum AircraftExteriorShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct AXParams {
        float4 a;   // x time (s), y rain coverage 0..1, z dirt age 0..1, w detail distance (m)
        float4 b;   // x rain streak angle (rad), y streak length (m), z flags bit0 rivets bit1 clearcoat bit2 dirt, w throttle
    };

    static float ax_hash(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    static float ax_vnoise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 w = f * f * (3.0 - 2.0 * f);
        return mix(mix(ax_hash(i), ax_hash(i + float2(1, 0)), w.x), mix(ax_hash(i + float2(0, 1)), ax_hash(i + float2(1, 1)), w.x), w.y);
    }

    /// Rivet dome: xy = tangent-plane normal tilt, z = height. `uv` in metres on the skin, `fp` pixel footprint (m).
    static float3 ax_rivet(float2 uv, float fp) {
        const float pitch = 0.032, radius = 0.0045;
        float fade = saturate(1.0 - fp / (pitch * 0.45));
        if (fade <= 0.0) return float3(0.0);
        float2 d = uv - round(uv / pitch) * pitch;
        float r = length(d) / radius;
        if (r >= 1.0) return float3(0.0, 0.0, 0.0);
        float h = sqrt(1.0 - r * r);
        float slope = r / max(h, 0.25);
        float2 dir = r > 1e-4 ? -d / (r * radius) : float2(0.0);
        return float3(dir * slope * fade, h * fade);
    }

    /// Fine brushed/orange-peel micro normal for the clearcoat; returns tilt xy.
    static float2 ax_orangePeel(float2 uv, float fp) {
        float fade = saturate(1.0 - fp / 0.02);
        float n1 = ax_vnoise(uv * 180.0), n2 = ax_vnoise(uv * 180.0 + 17.3);
        return (float2(n1, n2) - 0.5) * 0.06 * fade;
    }

    /// Perturb `n` by tangent-plane tilt `t` (tangent frame from the geometric normal).
    static float3 ax_tilt(float3 n, float2 t) {
        float3 up = abs(n.z) < 0.99 ? float3(0, 0, 1) : float3(1, 0, 0);
        float3 tu = normalize(cross(up, n)), tv = cross(n, tu);
        return normalize(n + tu * t.x + tv * t.y);
    }

    /// Second (clearcoat) specular lobe: GGX, F0 = 0.04, very smooth. Returns radiance factor to add; the base
    /// layer should be scaled by `1 - coatF` (returned in .w).
    static float4 ax_clearcoat(float3 n, float3 v, float3 l, float3 sunRadiance, float vis) {
        float3 h = normalize(v + l);
        float nh = saturate(dot(n, h)), nl = saturate(dot(n, l)), nv = max(dot(n, v), 1e-3), vh = saturate(dot(v, h));
        float a = 0.05 * 0.05;                                  // roughness 0.05 -> alpha
        float d = nh * nh * (a - 1.0) + 1.0;
        float D = a / (3.14159265 * d * d);
        float F = 0.04 + 0.96 * pow(1.0 - vh, 5.0);
        float k = (0.05 + 1.0) * (0.05 + 1.0) / 8.0;
        float G = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k));
        float3 spec = sunRadiance * (D * F * G / max(4.0 * nv, 1e-3)) * vis;
        float Fv = 0.04 + 0.96 * pow(1.0 - nv, 5.0);
        return float4(spec, Fv);
    }

    /// Exhaust/oil stain and general grime on the body (axes x fwd, y right, z down). 0 clean .. 1 dark.
    static float ax_dirt(float3 L, float age, float fp) {
        float soot = 0.0;
        if (L.x < 1.9 && L.z > 0.1) {
            float aft = 1.9 - L.x;
            float width = 0.08 + 0.11 * aft;
            float across = abs(L.y - 0.05 * aft) / width;
            soot = max(0.0, 1.0 - across * across) * exp(-aft / 2.6) * 0.85;
            // Streaks along the airflow, broken up by noise.
            soot *= 0.65 + 0.35 * ax_vnoise(float2(L.x * 2.0, L.y * 40.0));
        }
        float belly = smoothstep(0.1, 0.35, L.z) * 0.35;
        float nose = smoothstep(2.0, 2.5, L.x) * 0.25 * (0.5 + 0.5 * ax_vnoise(L.yz * 25.0));
        float grime = (belly + nose) * (0.7 + 0.3 * ax_vnoise(L.xy * 6.0));
        return saturate((grime + soot * 0.9) * age) * saturate(1.0 - fp / 0.5);
    }

    /// Rain on a glass point. `uv` metres across the pane (v aft), returns x = water coverage, yz = refraction
    /// tilt for the normal. Drops are dragged along `ang` (0 = straight down) as streaks of length `len`.
    static float3 ax_rain(float2 uv, float cover, float ang, float len, float t, int layers) {
        float3 acc = float3(0.0);
        float2 dir = float2(sin(ang), cos(ang));       // streak direction on the glass
        float2 perp = float2(dir.y, -dir.x);
        for (int i = 0; i < layers; i++) {
            float scale = 22.0 + 14.0 * float(i);
            float2 q = float2(dot(uv, perp), dot(uv, dir)) * scale + float(i) * 7.7;
            float2 cell = floor(q), f = fract(q) - 0.5;
            float h = ax_hash(cell + float(i) * 13.1);
            if (h > cover) continue;
            float slide = fract(h * 7.0 + t * (0.05 + 0.2 * h) * (0.2 + len * 4.0));
            float cy = (slide - 0.5) * 0.6;
            float2 e = float2(f.x * 2.2, (f.y - cy) / max(0.3, 1.0 + len * 30.0));
            float drop = saturate(1.0 - dot(e, e) * 4.0);
            acc.x = max(acc.x, drop);
            acc.yz += -e * drop * 0.4;
        }
        return acc;
    }

    /// Propeller disc opacity: blur from blade angular motion over one exposure; `rpm`, `blades`.
    static float ax_propOpacity(float r, float th, float rpm, int blades, float shutter, float time) {
        float sweep = abs(rpm) / 60.0 * shutter * 6.2831853;
        float spacing = 6.2831853 / float(max(blades, 1));
        float blur = smoothstep(0.15 * spacing, spacing, sweep);
        float solidity = min(1.0, float(blades) * 0.11 / (3.14159265 * 0.95));
        float ang = th - time * rpm / 60.0 * 6.2831853;
        float bladeCov = smoothstep(0.35, 0.0, abs(sin(ang * float(blades) * 0.5))) ;   // sharp blades when slow
        float veil = solidity * (0.4 + 0.6 * smoothstep(0.15, 0.9, r));
        return mix(bladeCov * 0.9, veil, blur);
    }

    /// Heat shimmer UV offset (pixels) behind the exhaust: `aft` metres behind it, `lat` off axis.
    static float2 ax_heatShimmer(float aft, float lat, float throttle, float time, float2 p) {
        if (aft <= 0.0) return float2(0.0);
        float w = lat / (0.25 + 0.18 * aft);
        float amp = 3.0 * saturate(throttle) * exp(-aft / 2.2) * max(0.0, 1.0 - w * w) * smoothstep(0.0, 0.3, aft);
        float2 q = p * 0.35 + float2(0.0, -time * 3.0);
        return (float2(ax_vnoise(q), ax_vnoise(q + 31.7)) - 0.5) * 2.0 * amp;
    }

    // MARK: Exterior light glow (camera-facing sprites)

    struct AXGlowIn { float4 posSize; float4 colour; };   // xyz camera-relative centre, w radius (m); rgb * HDR intensity, a unused
    struct AXGlowVarying { float4 position [[position]]; float2 uv; float3 colour; };

    vertex AXGlowVarying ax_glow_vertex(const device AXGlowIn* lights [[buffer(0)]], constant float4x4& viewProj [[buffer(1)]],
                                        constant float4x4& view [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        float2 c = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0);
        AXGlowIn g = lights[iid];
        float3 right = float3(view[0][0], view[1][0], view[2][0]);
        float3 up = float3(view[0][1], view[1][1], view[2][1]);
        float3 p = g.posSize.xyz + (right * c.x + up * c.y) * g.posSize.w;
        AXGlowVarying o;
        o.position = viewProj * float4(p, 1.0);
        o.uv = c;
        o.colour = g.colour.rgb;
        return o;
    }

    /// Hot white core + coloured halo with a 1/r^2 tail; additive blend.
    fragment float4 ax_glow_fragment(AXGlowVarying in [[stage_in]]) {
        float r2 = dot(in.uv, in.uv);
        if (r2 >= 1.0) discard_fragment();
        float core = exp(-r2 * 28.0);
        float halo = 0.06 / (0.02 + r2) * (1.0 - r2) * (1.0 - r2);
        float3 c = in.colour * halo + mix(in.colour, float3(1.0), 0.65) * core * 2.0;
        return float4(c, 1.0);
    }
    """
}
