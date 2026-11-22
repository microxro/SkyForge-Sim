// SKYFORGE — Apache-2.0
// Round 4: cockpit contact shadows and fine-scale ambient occlusion, a full-screen pass over the HDR scene
// before bloom. The scene's SSAO uses a 2.5 m radius, far too coarse for a switch on a panel; this pass uses
// 4–8 cm and also marches a short ray toward the sun through the depth buffer, so switches, yoke shafts and
// the glare shield's lip cast thin, soft shadows. It multiplies the colour buffer (blend: zero, destination ×
// source), so it needs no read-write texture, and it ignores everything farther than the cabin.
#if canImport(Metal)
import Metal
import simd

public enum CockpitContactShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CKVarying { float4 position [[position]]; float2 uv; };
    vertex CKVarying cockpit_contact_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        CKVarying o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    struct CKContactParams {
        float4 proj;      // near (m), tan(half fov x), tan(half fov y), cabin depth (m): farther pixels are untouched
        float4 sunView;   // unit vector to the sun in view space (x right, y up, z forward), w = direct share of the light (0…1)
        float4 shape;     // shadow reach (m), AO radius (m), shadow strength, AO strength
    };

    static float3 ck_view(float2 uv, float z, float4 p) {
        float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
        return float3(ndc.x * p.y * z, ndc.y * p.z * z, z);
    }
    static float2 ck_uv(float3 P, float4 p) {
        return float2(P.x / (p.y * P.z) * 0.5 + 0.5, 0.5 - P.y / (p.z * P.z) * 0.5);
    }
    static float ck_ign(float2 px) { return fract(52.9829189 * fract(dot(px, float2(0.06711056, 0.00583715)))); }

    /// Reversed infinite Z: view distance = near / depth. Returns 0 for the sky.
    static float ck_zAt(depth2d<float> depth, int2 q, float near) {
        float d = depth.read(uint2(q));
        return d > 0.0 ? near / d : 0.0;
    }

    fragment float4 cockpit_contact_fragment(CKVarying in [[stage_in]], depth2d<float> depth [[texture(0)]],
                                             constant CKContactParams& cp [[buffer(0)]]) {
        int2 size = int2(depth.get_width(), depth.get_height());
        int2 px = int2(min(in.position.xy, float2(size) - 1.0));
        float4 p = cp.proj;
        float z = ck_zAt(depth, px, p.x);
        if (z <= 0.0 || z > p.w + 0.5) return float4(1.0);
        float mask = 1.0 - smoothstep(p.w, p.w + 0.5, z);
        float3 P = ck_view(in.uv, z, p);
        // Normal from the depth buffer, taking the smaller one-sided difference on each axis so a silhouette edge
        // does not smear. (dfdx/dfdy would be undefined here: the early return above is non-uniform control flow.)
        float2 fs = float2(size);
        int2 qx0 = int2(max(px.x - 1, 0), px.y), qx1 = int2(min(px.x + 1, size.x - 1), px.y);
        int2 qy0 = int2(px.x, max(px.y - 1, 0)), qy1 = int2(px.x, min(px.y + 1, size.y - 1));
        float zx0 = ck_zAt(depth, qx0, p.x), zx1 = ck_zAt(depth, qx1, p.x);
        float zy0 = ck_zAt(depth, qy0, p.x), zy1 = ck_zAt(depth, qy1, p.x);
        bool useX1 = zx1 > 0.0 && (zx0 <= 0.0 || abs(zx1 - z) < abs(zx0 - z));
        bool useY1 = zy1 > 0.0 && (zy0 <= 0.0 || abs(zy1 - z) < abs(zy0 - z));
        float3 tx = useX1 ? ck_view((float2(qx1) + 0.5) / fs, zx1, p) - P : P - ck_view((float2(qx0) + 0.5) / fs, zx0, p);
        float3 ty = useY1 ? ck_view((float2(qy1) + 0.5) / fs, zy1, p) - P : P - ck_view((float2(qy0) + 0.5) / fs, zy0, p);
        float3 cn = cross(tx, ty);
        float cl2 = dot(cn, cn);
        float3 N = (zx0 > 0.0 || zx1 > 0.0) && (zy0 > 0.0 || zy1 > 0.0) && cl2 > 1e-14 ? cn * rsqrt(cl2) : float3(0.0, 0.0, -1.0);
        if (N.z > 0.0) N = -N;                                    // face the camera (looking along +z)
        float3 L = normalize(cp.sunView.xyz);
        float ndl = dot(N, L);
        float jitter = ck_ign(in.position.xy);

        // Contact shadow: 16 steps toward the sun over `reach` metres, spaced closer near the surface.
        float reach = cp.shape.x, occ = 0.0;
        if (ndl > 0.02) {
            const int K = 16;
            for (int i = 0; i < K; i++) {
                float f = (float(i) + jitter) / float(K);
                float t = reach * f * f;
                float3 S = P + N * (0.0015 + 0.004 * z) + L * t;
                if (S.z < p.x * 1.5) break;
                float2 uv = ck_uv(S, p);
                if (uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0) break;
                float zq = ck_zAt(depth, int2(uv * float2(size)), p.x);
                if (zq <= 0.0) continue;
                float delta = S.z - zq;                           // > 0: the ray point is behind the visible surface
                float bias = 0.0015 + 0.004 * t, thick = 0.05 + 0.6 * t;
                float hit = smoothstep(bias, bias * 3.0, delta) * (1.0 - smoothstep(thick, thick * 2.0, delta));
                occ = max(occ, hit * (1.0 - 0.6 * f));            // darkest at the contact, softer farther out
            }
        }

        // Fine AO (Alchemy form, as the scene SSAO) at centimetre scale.
        float radius = cp.shape.y;
        float rPx = radius / (z * p.z) * float(size.y) * 0.5;
        float ao = 1.0;
        if (rPx >= 1.0) {
            rPx = min(rPx, 48.0);
            float ang = 6.2831853 * jitter, sum = 0.0;
            const int A = 12;
            for (int k = 0; k < A; k++) {
                float t = (float(k) + 0.5) / float(A);
                float a = ang + float(k) * 2.39996323;
                int2 q = px + int2(float2(cos(a), sin(a)) * rPx * t);
                if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) continue;
                float zq = ck_zAt(depth, q, p.x);
                if (zq <= 0.0) continue;
                float3 v = ck_view((float2(q) + 0.5) / float2(size), zq, p) - P;
                float vv = dot(v, v);
                float fall = saturate(1.0 - vv / (radius * radius * 4.0));
                sum += max(0.0, dot(v, N) - 0.02 * z) / (vv + 0.02 * radius * radius) * fall;   // 1/m: × radius below makes it dimensionless
            }
            ao = saturate(1.0 - 1.2 * radius * sum / float(A));
        }

        float shadow = 1.0 - cp.sunView.w * cp.shape.z * occ * smoothstep(0.02, 0.15, ndl);
        float amb = 1.0 - cp.shape.w * (1.0 - ao);
        float f = shadow * amb;
        return float4(float3(mix(1.0, f, mask)), 1.0);
    }
    """
}

/// Draws the cockpit contact-shadow pass into the HDR scene buffer.
public final class CockpitContactPass {
    /// Matches `CKContactParams` (three float4s).
    struct Params {
        var proj: SIMD4<Float>
        var sunView: SIMD4<Float>
        var shape: SIMD4<Float>
    }

    public var shadowReach: Float = 0.16
    public var aoRadius: Float = 0.06
    public var shadowStrength: Float = 0.85
    public var aoStrength: Float = 0.9
    /// Everything farther than this (m) from the eye is left alone: the cabin is about 1.8 m deep.
    public var cabinDepth: Float = 1.8

    private let pipeline: MTLRenderPipelineState

    public init(device: MTLDevice, colorFormat: MTLPixelFormat = .rgba16Float) throws {
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: CockpitContactShaders.source, options: nil) }
        catch { throw RendererError.shaderCompile(String(describing: error)) }
        guard let v = lib.makeFunction(name: "cockpit_contact_vertex"), let f = lib.makeFunction(name: "cockpit_contact_fragment") else {
            throw RendererError.shaderCompile("missing cockpit contact functions")
        }
        let d = MTLRenderPipelineDescriptor()
        d.label = "CockpitContact"
        d.vertexFunction = v
        d.fragmentFunction = f
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = colorFormat
        ca.isBlendingEnabled = true
        // result = destination × source colour (the pass writes a visibility factor)
        ca.sourceRGBBlendFactor = .zero; ca.destinationRGBBlendFactor = .sourceColor
        ca.sourceAlphaBlendFactor = .zero; ca.destinationAlphaBlendFactor = .one
        do { pipeline = try device.makeRenderPipelineState(descriptor: d) }
        catch { throw RendererError.pipeline(String(describing: error)) }
    }

    /// Multiplies `scene` by the cabin's contact shadow and fine AO. `depth` is the scene's reversed-Z depth
    /// (as the SSAO pass reads it); `forward`/`up` the camera basis used for the view matrix, `toSun` the
    /// world direction to the sun (z up), and `directShare` the fraction of cabin light that comes straight
    /// from the sun (0 under cloud or with the sun below the horizon; about 0.55 in clear midday sun).
    public func encode(cmd: MTLCommandBuffer, scene: MTLTexture, depth: MTLTexture, near: Float, fovY: Float, aspect: Float,
                       forward: SIMD3<Float>, up: SIMD3<Float>, toSun: SIMD3<Float>, directShare: Float) throws {
        let tanY = tan(fovY / 2), tanX = tanY * aspect
        let f = simd_normalize(forward)
        let r = simd_normalize(simd_cross(f, up))
        let u = simd_cross(r, f)
        let s = SIMD3(simd_dot(toSun, r), simd_dot(toSun, u), simd_dot(toSun, f))
        var params = Params(proj: SIMD4(near, tanX, tanY, cabinDepth),
                            sunView: SIMD4(s.x, s.y, s.z, max(0, min(1, directShare))),
                            shape: SIMD4(shadowReach, aoRadius, shadowStrength, aoStrength))
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = scene
        pd.colorAttachments[0].loadAction = .load
        pd.colorAttachments[0].storeAction = .store
        guard let e = cmd.makeRenderCommandEncoder(descriptor: pd) else { throw RendererError.commandQueue }
        e.label = "CockpitContact"
        e.setRenderPipelineState(pipeline)
        e.setFragmentTexture(depth, index: 0)
        e.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        e.endEncoding()
    }
}
#endif
