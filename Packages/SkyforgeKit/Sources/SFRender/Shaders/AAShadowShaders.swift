// SKYFORGE — Apache-2.0
// Round 5: TAA resolve (Halton jitter, depth-based reprojection, YCoCg variance clipping), a low-tier
// luma edge AA (SMAA-lite), and 4-cascade sun shadow lookup with blending and PCSS. Concatenate after
// PostShaders.source (for PostVarying) and WorldShaders.source (for shadowCmp).

public enum AAShadowShaders {
    public static let source = """
    struct TAAParams {
        float4x4 invViewProj;       // current, jitter-free, camera-relative
        float4x4 prevViewProj;      // previous, jitter-free, same camera-relative origin (translated by camera delta)
        float4 p;                   // x = base blend (0.1), y = clip gamma (1.25), z = 1 first frame / history invalid, w = unused
    };

    static float3 rgb2ycocg(float3 c) { return float3(0.25*c.x + 0.5*c.y + 0.25*c.z, 0.5*c.x - 0.5*c.z, -0.25*c.x + 0.5*c.y - 0.25*c.z); }
    static float3 ycocg2rgb(float3 c) { return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z); }

    constexpr sampler taaLinear(filter::linear, address::clamp_to_edge);
    constexpr sampler taaNearest(filter::nearest, address::clamp_to_edge);

    fragment float4 taa_resolve_fragment(PostVarying in [[stage_in]], texture2d<float> cur [[texture(0)]],
                                         texture2d<float> hist [[texture(1)]], depth2d<float> depth [[texture(2)]],
                                         constant TAAParams& tp [[buffer(0)]]) {
        float2 ts = 1.0 / float2(cur.get_width(), cur.get_height());
        float3 c0 = cur.sample(taaNearest, in.uv).rgb;
        // Closest depth in the 3x3 (keeps silhouettes sharp when reprojecting).
        float dz = 0.0; float2 dOff = float2(0.0);
        float3 m1 = float3(0.0), m2 = float3(0.0);
        for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
            float2 o = float2(x, y) * ts;
            float3 s = rgb2ycocg(cur.sample(taaNearest, in.uv + o).rgb);
            m1 += s; m2 += s * s;
            float d = depth.sample(taaNearest, in.uv + o);
            if (d > dz) { dz = d; dOff = o; }   // reversed or forward Z: pass the matching sign via invViewProj
        }
        m1 /= 9.0; m2 /= 9.0;
        float3 sigma = sqrt(max(m2 - m1 * m1, 0.0));
        float3 lo = m1 - tp.p.y * sigma, hi = m1 + tp.p.y * sigma;
        float4 ndc = float4((in.uv + dOff) * float2(2.0, -2.0) + float2(-1.0, 1.0), dz, 1.0);
        float4 w = tp.invViewProj * ndc; w /= w.w;
        float4 pc = tp.prevViewProj * w;
        float2 puv = pc.xy / pc.w * float2(0.5, -0.5) + 0.5;
        bool valid = tp.p.z < 0.5 && pc.w > 0.0 && all(puv > 0.0) && all(puv < 1.0);
        if (!valid) return float4(c0, 1.0);
        float3 h = rgb2ycocg(hist.sample(taaLinear, puv).rgb);
        float3 mid = 0.5 * (hi + lo), e = 0.5 * (hi - lo) + 1e-5;
        float3 v = h - mid;
        float k = max(abs(v.x) / e.x, max(abs(v.y) / e.y, abs(v.z) / e.z));
        float clipped = max(k - 1.0, 0.0);
        if (k > 1.0) h = mid + v / k;
        float a = min(1.0, tp.p.x + min(0.4, clipped * 0.5));
        return float4(max(ycocg2rgb(mix(h, rgb2ycocg(c0), a)), 0.0), 1.0);
    }

    // SMAA-lite for the low tier: luma edge detect, then blend along the edge normal by the edge's
    // sub-pixel offset (a cheaper, single-pass cousin of morphological AA).
    fragment float4 smaa_lite_fragment(PostVarying in [[stage_in]], texture2d<float> t [[texture(0)]]) {
        float2 ts = 1.0 / float2(t.get_width(), t.get_height());
        float3 c = t.sample(taaLinear, in.uv).rgb;
        float3 lw = float3(0.299, 0.587, 0.114);
        float l = dot(c, lw);
        float lL = dot(t.sample(taaLinear, in.uv + float2(-ts.x, 0)).rgb, lw);
        float lR = dot(t.sample(taaLinear, in.uv + float2( ts.x, 0)).rgb, lw);
        float lU = dot(t.sample(taaLinear, in.uv + float2(0, -ts.y)).rgb, lw);
        float lD = dot(t.sample(taaLinear, in.uv + float2(0,  ts.y)).rgb, lw);
        float eh = max(abs(l - lU), abs(l - lD)), ev = max(abs(l - lL), abs(l - lR));
        float thr = 0.1;
        if (max(eh, ev) < thr) return float4(c, 1.0);
        // Blend toward the neighbour across the stronger edge by half the contrast ratio (capped).
        float2 dir; float other;
        if (eh >= ev) { bool up = abs(l - lU) > abs(l - lD); dir = float2(0, up ? -ts.y : ts.y); other = up ? lU : lD; }
        else          { bool lf = abs(l - lL) > abs(l - lR); dir = float2(lf ? -ts.x : ts.x, 0); other = lf ? lL : lR; }
        float w = clamp(abs(l - other) / (abs(l - other) + abs(l) + 1e-4), 0.0, 0.5);
        float3 n = t.sample(taaLinear, in.uv + dir).rgb;
        return float4(mix(c, n, w), 1.0);
    }

    // ---- 4-cascade sun shadows -------------------------------------------------------------------------
    struct CascadeShadowParams {
        float4x4 vp[4];             // camera-relative world → cascade clip, texel-snapped on the CPU
        float4 splits;              // far edge (m) of cascades 0…3
        float4 texel;               // texel size (m) per cascade
        float4 depthRange;          // light-space depth range (m) per cascade
        float4 q;                   // x = blend fraction, y = PCF radius / tap count scale, z = PCSS on, w = sun tan(angular radius)
    };

    static float casIGN(float2 p) { return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))); }

    // Vogel-disk PCF, rotated per pixel by interleaved gradient noise; the radius is in texels.
    static float casPCF(depth2d_array<float> sm, float2 uv, float z, uint layer, float radiusTexels, int taps, float2 pix) {
        float2 ts = 1.0 / float2(sm.get_width(), sm.get_height());
        float rot = 6.2831853 * casIGN(pix);
        float lit = 0.0;
        for (int i = 0; i < taps; i++) {
            float r = sqrt((float(i) + 0.5) / float(taps)), a = 2.39996323 * float(i) + rot;
            lit += sm.sample_compare(shadowCmp, uv + float2(cos(a), sin(a)) * r * radiusTexels * ts, layer, z);
        }
        return lit / float(taps);
    }

    // Average blocker depth (in cascade depth units 0…1) within a search radius, or -1 when none.
    static float casBlocker(depth2d_array<float> sm, float2 uv, float z, uint layer, float searchTexels, float2 pix) {
        float2 ts = 1.0 / float2(sm.get_width(), sm.get_height());
        float rot = 6.2831853 * casIGN(pix + 17.0);
        float sum = 0.0; float n = 0.0;
        for (int i = 0; i < 12; i++) {
            float r = sqrt((float(i) + 0.5) / 12.0), a = 2.39996323 * float(i) + rot;
            float d = sm.sample(taaNearest, uv + float2(cos(a), sin(a)) * r * searchTexels * ts, layer);
            if (d < z) { sum += d; n += 1.0; }
        }
        return n > 0.0 ? sum / n : -1.0;
    }

    static float casCascadeVis(constant CascadeShadowParams& cp, depth2d_array<float> sm, float3 rel, float3 nrm, float ndl, int c, float2 pix) {
        float texel = cp.texel[c], range = cp.depthRange[c];
        float tanT = sqrt(max(0.0, 1.0 - ndl * ndl)) / max(ndl, 0.05);
        float3 p = rel + nrm * texel * 1.5;
        float4 lp = cp.vp[c] * float4(p, 1.0);
        float2 uv = lp.xy * float2(0.5, -0.5) + 0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) return -1.0;   // outside this cascade: caller falls back
        float z = lp.z - texel * (0.8 + min(16.0, tanT * 1.4)) / range;
        int taps = int(cp.q.y);
        float radius = 1.5;
        if (cp.q.z > 0.5) {
            // PCSS: blocker distance (m) → penumbra width (m) → texels.
            float b = casBlocker(sm, uv, z, uint(c), 4.0, pix);
            if (b < 0.0) return 1.0;
            float sep = max(0.0, (z - b) * range);
            radius = clamp(sep * cp.q.w / texel, 1.5, 12.0);
        }
        return casPCF(sm, uv, z, uint(c), radius, taps, pix);
    }

    /// Sun visibility with up to 4 cascades and a cross-fade into the next cascade near each far edge. 1 = lit.
    static float cascadedShadowVisibility(constant CascadeShadowParams& cp, depth2d_array<float> sm, float3 rel, float3 nrm, float dist, float ndl, float2 pix) {
        int c = dist < cp.splits.x ? 0 : (dist < cp.splits.y ? 1 : (dist < cp.splits.z ? 2 : (dist < cp.splits.w ? 3 : -1)));
        if (c < 0) return 1.0;
        float vis = casCascadeVis(cp, sm, rel, nrm, ndl, c, pix);
        if (vis < 0.0) { vis = c < 3 ? casCascadeVis(cp, sm, rel, nrm, ndl, c + 1, pix) : 1.0; if (vis < 0.0) vis = 1.0; return vis; }
        float start = c == 0 ? 0.0 : cp.splits[c - 1];
        float span = cp.splits[c] - start;
        float begin = cp.splits[c] - span * cp.q.x;
        float t = clamp((dist - begin) / max(1e-4, cp.splits[c] - begin), 0.0, 1.0);
        if (t > 0.0 && c < 3) {
            float v2 = casCascadeVis(cp, sm, rel, nrm, ndl, c + 1, pix);
            if (v2 >= 0.0) vis = mix(vis, v2, t * t * (3.0 - 2.0 * t));
        }
        // Fade to lit over the last 5% of the final cascade so the far edge does not pop.
        if (c == 3) vis = mix(vis, 1.0, clamp((dist - cp.splits.w * 0.95) / (cp.splits.w * 0.05), 0.0, 1.0));
        return vis;
    }
    """
}
