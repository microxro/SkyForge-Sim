// SKYFORGE — Apache-2.0
// GPU-driven culling of building batches: frustum, distance and Hi-Z occlusion in one compute pass that writes
// `MTLDrawIndexedPrimitivesIndirectArguments`, plus the two kernels that build the Hi-Z pyramid from the previous
// frame's reversed-Z depth (1 = near, 0 = far, so the pyramid keeps the per-tile MINIMUM, the farthest surface).
// Host side: BuildingCuller.swift. CPU reference of the frustum/distance tests: BuildingBatching.visible.

public enum BuildingCullShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Same bytes as Swift GPUCullCell: eight 4-byte scalars.
    struct CullCell { packed_float3 bmin; uint indexStart; packed_float3 bmax; uint indexCount; };
    // Same bytes as Swift IndirectDrawArgs / MTLDrawIndexedPrimitivesIndirectArguments.
    struct IndirectArgs { uint indexCount; uint instanceCount; uint indexStart; int baseVertex; uint baseInstance; };

    struct CullUniforms {
        float4x4 mvp;
        float4x4 hizMvp;
        float4 plane0; float4 plane1; float4 plane2; float4 plane3; float4 plane4; float4 plane5;
        float4 cameraLocal;     // xyz mesh-local camera, w maximum distance (m)
        float4 hizInfo;         // width, height, mip count, 1 = occlusion on
        float4 params;          // x depth bias, y minimum screen size (px) for the occlusion test
        uint4 counts;           // x cell count
    };

    kernel void building_cull(device const CullCell* cells [[buffer(0)]],
                              device IndirectArgs* args [[buffer(1)]],
                              constant CullUniforms& u [[buffer(2)]],
                              device atomic_uint* stats [[buffer(3)]],   // visible, frustum, occluded, distance
                              texture2d<float, access::read> hiz [[texture(0)]],
                              uint gid [[thread_position_in_grid]]) {
        if (gid >= u.counts.x) return;
        CullCell c = cells[gid];
        float3 lo = float3(c.bmin), hi = float3(c.bmax);
        IndirectArgs a;
        a.indexCount = c.indexCount; a.indexStart = c.indexStart; a.baseVertex = 0; a.baseInstance = 0; a.instanceCount = 0;

        // 1. Distance: nearest point of the box to the camera.
        float3 cam = u.cameraLocal.xyz;
        float3 d3 = max(max(lo - cam, cam - hi), float3(0.0));
        if (length(d3) > u.cameraLocal.w) {
            args[gid] = a; atomic_fetch_add_explicit(&stats[3], 1u, memory_order_relaxed); return;
        }
        // 2. Frustum: the box against six planes (positive-vertex test).
        float4 planes[6] = { u.plane0, u.plane1, u.plane2, u.plane3, u.plane4, u.plane5 };
        for (int i = 0; i < 6; i++) {
            float4 p = planes[i];
            float3 v = float3(p.x >= 0.0 ? hi.x : lo.x, p.y >= 0.0 ? hi.y : lo.y, p.z >= 0.0 ? hi.z : lo.z);
            if (dot(p.xyz, v) + p.w < 0.0) {
                args[gid] = a; atomic_fetch_add_explicit(&stats[1], 1u, memory_order_relaxed); return;
            }
        }
        // 3. Hi-Z occlusion against last frame's depth. A box holding the camera, or with a corner behind the
        //    hiz camera's near plane, is never occluded (conservative).
        bool occluded = false;
        if (u.hizInfo.w > 0.5 && !(all(cam >= lo - float3(2.0)) && all(cam <= hi + float3(2.0)))) {
            float2 umin = float2(1e9), umax = float2(-1e9);
            float zNear = 0.0;                                 // reversed-Z: nearest = largest
            bool behind = false;
            for (int k = 0; k < 8; k++) {
                float3 p = float3((k & 1) ? hi.x : lo.x, (k & 2) ? hi.y : lo.y, (k & 4) ? hi.z : lo.z);
                float4 q = u.hizMvp * float4(p, 1.0);
                if (!(q.w > 1e-4)) { behind = true; break; }   // also catches NaN
                float3 ndc = q.xyz / q.w;
                float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
                umin = min(umin, uv); umax = max(umax, uv);
                zNear = max(zNear, ndc.z);
            }
            if (!behind) {
                umin = clamp(umin, float2(0.0), float2(1.0)); umax = clamp(umax, float2(0.0), float2(1.0));
                float2 size = u.hizInfo.xy;
                float2 px = (umax - umin) * size;
                if (max(px.x, px.y) >= u.params.y && umax.x > umin.x && umax.y > umin.y) {
                    // Mip where the rectangle spans at most two texels per axis (BuildingBatching.hizMip).
                    uint mip = uint(clamp(int(ceil(log2(max(max(px.x, px.y), 1.0)))) - 1, 0, int(u.hizInfo.z) - 1));
                    float2 msz = max(float2(1.0), floor(size / float(1u << mip)));
                    uint2 t0 = uint2(clamp(floor(umin * msz), float2(0.0), msz - float2(1.0)));
                    uint2 t1 = uint2(clamp(floor(umax * msz), float2(0.0), msz - float2(1.0)));
                    // A rectangle of up to two texels can straddle three, so scan the whole span (at most 3x3 reads).
                    // When the top mip clamps (a very large rectangle) the span can exceed three texels; the scan then
                    // cannot cover it, so the box is never culled by occlusion (conservative).
                    if (t1.x - t0.x <= 2u && t1.y - t0.y <= 2u) {
                        float m = 1e30;
                        for (uint ty = t0.y; ty <= t1.y; ty++)
                            for (uint tx = t0.x; tx <= t1.x; tx++)
                                m = min(m, hiz.read(uint2(tx, ty), mip).x);
                        // Farthest surface in the rectangle is nearer than the box's nearest point: hidden.
                        occluded = zNear + u.params.x < m;
                    }
                }
            }
        }
        if (occluded) { args[gid] = a; atomic_fetch_add_explicit(&stats[2], 1u, memory_order_relaxed); return; }
        a.instanceCount = 1;
        args[gid] = a;
        atomic_fetch_add_explicit(&stats[0], 1u, memory_order_relaxed);
    }

    /// Mip 0 of the pyramid: a straight copy of the resolved depth.
    kernel void hiz_copy(depth2d<float, access::read> depth [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        dst.write(float4(depth.read(gid), 0.0, 0.0, 0.0), gid);
    }

    /// Mip n from mip n−1: the minimum (farthest, reversed-Z) of each 2×2, with odd edges clamped.
    kernel void hiz_downsample(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        uint2 sz = uint2(src.get_width(), src.get_height());
        uint2 m = sz - 1;
        uint2 b = gid * 2;
        // An odd source side has one texel more than 2 x dst: the last dst texel takes three so none is dropped
        // (dropping one would raise the minimum and over-cull).
        uint2 last = uint2(dst.get_width() - 1, dst.get_height() - 1);
        uint2 e = b + uint2(1) + uint2((gid.x == last.x) && (sz.x & 1u) != 0u ? 1u : 0u,
                                       (gid.y == last.y) && (sz.y & 1u) != 0u ? 1u : 0u);
        e = min(e, m);
        float v = 1e30;
        for (uint y = min(b.y, m.y); y <= e.y; y++)
            for (uint x = min(b.x, m.x); x <= e.x; x++)
                v = min(v, src.read(uint2(x, y)).x);
        dst.write(float4(v, 0.0, 0.0, 0.0), gid);
    }
    """
}
