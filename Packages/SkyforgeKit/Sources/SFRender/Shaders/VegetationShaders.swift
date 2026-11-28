// SKYFORGE — Apache-2.0
// Round 5 vegetation shaders. Vertex stages emit `WorldVarying` so the existing `world_fragment` lights them
// (see docs/rounds/ROUND5_vegetation.md for the two lines to add there). Reuses `treeShape` and the world
// structs, so this literal is concatenated after WorldShaders.source.
//   veg_vertex / shadow_veg_vertex  full and card meshes, wind sway, seasonal tint and leaf drop, LOD band
//   veg_billboard_vertex            camera-facing impostor quad per tree, procedural silhouette (no bake)
//   grass_vertex                    near-camera blades, thinned toward the radius
// The LOD cross-fade is a per-pixel dither: each representation is kept where the screen noise falls in its
// [lo, hi) slice of 0…1 (passed in `style.yz`), so exactly one draws each pixel and nothing pops.

public enum VegetationShaders {

    /// Helpers that `world_fragment` needs (hash, dither, LOD fade gate): concatenate BEFORE WorldShaders.source.
    public static let common = """
    #include <metal_stdlib>
    using namespace metal;

    static uint vegHash(uint h) { h ^= h >> 16; h *= 0x7FEB352Du; h ^= h >> 15; h *= 0x846CA68Bu; h ^= h >> 16; return h; }
    static float vegUnit(uint h) { return float(vegHash(h) & 0xFFFFFFu) / 16777216.0; }
    static float vegSmooth(float a, float b, float x) { float t = saturate((x - a) / (b - a)); return t * t * (3.0 - 2.0 * t); }

    /// Interleaved gradient noise, the same as VegetationLOD.dither.
    static float veg_dither(float2 p) { return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715)))); }

    /// Fragment gate: call at the top of world_fragment as `if (!veg_keep(in.style, in.position.xy, in.uv, in.local)) discard_fragment();`
    /// style = (marker -1, lo, hi, kind 0 solid / 1 leaf card / 2 billboard); kind 2 reads board in uv.
    static bool veg_keep(float4 style, float2 frag, float2 uv, float3 local) {
        if (style.x > -0.5) return true;          // not vegetation (buildings use style.x as a seed, others 0)
        float n = veg_dither(frag);
        if (n < style.y || n >= style.z) return false;
        if (style.w > 1.5) {                       // billboard silhouette: a crown ellipse with a noisy rim and a trunk
            float2 c = float2(0.5, local.x);
            float2 q = (uv - c) / float2(0.5, max(0.05, local.y));
            float rim = 1.0 - length(q);
            float noise = vegUnit(uint(floor(uv.x * 23.0)) * 73856093u ^ uint(floor(uv.y * 31.0)) * 19349663u) - 0.5;
            bool crown = rim + 0.22 * noise > 0.0;
            bool trunk = abs(uv.x - 0.5) < 0.035 && uv.y < local.x;
            return crown || trunk;
        }
        if (style.w > 0.5) {                       // leaf card: three overlapping blobs
            float a = 0.0;
            for (int i = 0; i < 3; i++) {
                float2 c = float2(0.3 + 0.2 * float(i), 0.5 + 0.12 * sin(float(i) * 2.1));
                a = max(a, 1.0 - length((uv - c) * float2(2.4, 3.0)));
            }
            return a > 0.0;
        }
        return true;
    }

    """

    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // 44 bytes: position, normal, shade, sway, card, uv (all 4-byte aligned; Swift mirror: VegVertexGPU, 11 Floats, stride 44; keep in sync, see gpuLayoutMatchesMSL).
    struct VegVertexGPU { packed_float3 position; packed_float3 normal; float shade; float sway; float card; packed_float2 uv; };
    struct GrassInstanceGPU { packed_float3 position; float height; float yaw; float tone; };

    struct VegUniforms {
        float4 wind;        // direction x, y (unit), speed m/s, gustiness
        float4 timeFade;    // time (s), full→card centre (m), card→billboard centre (m), fade width (m)
        float4 season;      // autumn, leaf drop, spring, sway enabled (0/1)
        float4 species;     // species index, stiffness, deciduous (0/1), representation (0 full, 1 card, 2 billboard)
        float4 board;       // billboard half width, half height (per unit tree height), crown centre y (0…1), crown radius y
        float4 barkLeaf;    // xyz = leaf albedo for this species, w unused
        float4 grass;       // rgb base blade colour, radius (m)
        float4 grassParams; // keep-fraction start (0…1 of radius), dryness 0…1, blade width scale, tree density keep fraction (veg_vertex; 1 = all)
    };

    /// Same maths as WindSway.offset on the CPU. `local` is unit-height tree space.
    static float3 veg_sway(float3 local, float weight, float time, float phase, float4 wind, float stiffness, float on) {
        float bend = max(0.0, local.z);
        float strength = min(1.0, wind.z / 20.0) / max(0.3, stiffness) * on;
        float slow = sin(time * 0.9 + phase) * 0.5 + 0.5 + wind.w * sin(time * 0.37 + phase * 1.7);
        float base = 0.035 * strength * bend * bend * (0.55 + slow);
        float vp = (local.x + local.y * 1.7 + local.z * 2.3) * 17.0;
        float flutter = 0.006 * strength * weight * sin(time * (5.0 + wind.z * 0.35) + vp + phase);
        float along = base * (0.4 + weight);
        return float3(wind.x * (along + flutter), wind.y * (along + flutter), -abs(along) * 0.06);
    }

    /// Slices of 0…1 for (full, card, billboard) at a distance; mirrors VegetationLOD.weights.
    static float3 veg_lod_weights(float dist, float4 timeFade) {
        float w = timeFade.w * 0.5;
        float toCard = vegSmooth(timeFade.y - w, timeFade.y + w, dist);
        float toBoard = vegSmooth(timeFade.z - w, timeFade.z + w, dist);
        return float3(1.0 - toCard, toCard * (1.0 - toBoard), toBoard);
    }

    static float2 veg_rep_range(float3 wt, float rep) {
        if (rep < 0.5) return float2(0.0, wt.x);
        if (rep < 1.5) return float2(wt.x, wt.x + wt.y);
        return float2(wt.x + wt.y, 1.001);
    }

    vertex WorldVarying veg_vertex(const device VegVertexGPU* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                   const device TreeInstanceGPU* inst [[buffer(2)]], constant VegUniforms& vu [[buffer(3)]],
                                   uint vid [[vertex_id]], uint iid [[instance_id]]) {
        TreeInstanceGPU t = inst[iid];
        VegVertexGPU w = v[vid];
        float3 local = float3(w.position);
        bool bark = w.shade < -0.5;
        float crownW, sz; float2 cs;
        float3 sl = treeShape(local, bark, float3(t.position), crownW, sz, cs);
        // Tree-level hash for phase and tint.
        uint th = as_type<uint>(int(floor(t.position.x * 4.0))) * 0x27D4EB2Du ^ as_type<uint>(int(floor(t.position.y * 4.0))) * 0x165667B1u;
        float tu = vegUnit(th), tv = vegUnit(th ^ 0x9E3779B9u);
        float phase = tu * 6.2831853;
        float3 sw = veg_sway(local, w.sway, vu.timeFade.x, phase, vu.wind, vu.species.y, vu.season.w);
        float3 pw = (sl + sw * float3(crownW, crownW, 1.0)) * t.height + float3(t.position);
        float4 p = u.model * float4(pw, 1.0);
        float dist = length(p.xyz);
        float2 rng = veg_rep_range(veg_lod_weights(dist, vu.timeFade), vu.species.w);
        float alive = rng.y > rng.x ? 1.0 : 0.0;
        // Fallen leaves: whole cards drop by a per-card hash (6 vertices per quad).
        bool leaf = w.card > 0.5;
        if (leaf && vu.species.z > 0.5 && vegUnit((vid / 6u) * 2654435761u ^ th) < vu.season.y) alive = 0.0;
        // Quality-ladder density: a per-tree hash keeps a stable subset, so a higher density keeps a superset of trees.
        if (vu.grassParams.w < 1.0 && vegUnit(th ^ 0x51ED270Bu) >= vu.grassParams.w) alive = 0.0;
        WorldVarying o;
        o.position = alive > 0.5 ? u.viewProj * p : float4(0.0, 0.0, 2.0, 1.0);   // outside the clip volume: culled
        o.rel = p.xyz;
        float3 n0 = float3(w.normal);
        float2 nxy = float2(cs.x * n0.x - cs.y * n0.y, cs.y * n0.x + cs.x * n0.y);
        o.normal = normalize(float3(nxy.x / crownW, nxy.y / crownW, n0.z / sz));
        if (bark) {
            float pale = vu.species.x == 5.0 ? 1.0 : 0.0;
            o.albedo = mix(float3(0.06, 0.045, 0.03), float3(0.55, 0.52, 0.46), pale);
            o.field = 1.0;
        } else {
            float3 leafC = float3(t.colour) * (0.85 + 0.3 * saturate(local.z)) * (0.82 + 0.36 * tv);
            // Seasonal tint: deciduous leaves go yellow / orange / red by a per-tree pick; spring lifts the green.
            if (vu.species.z > 0.5) {
                float3 pick = tu < 0.333 ? float3(4.2, 2.6, 0.6) : (tu < 0.666 ? float3(4.0, 1.5, 0.45) : float3(3.2, 0.6, 0.45));
                float a = vu.season.x * (0.6 + 0.4 * tv);
                float3 tint = mix(float3(1.0), pick, a);
                tint = mix(tint, float3(1.15, 1.2, 0.8), 0.3 * vu.season.z);
                leafC *= tint;
            }
            o.albedo = leafC;
            o.field = saturate(w.shade);
        }
        o.material = bark ? 0.0 : 2.0;
        o.local = float3(0.0);
        o.uv = float2(w.uv);
        o.style = float4(-1.0, rng.x, rng.y, leaf ? 1.0 : 0.0);
        return o;
    }

    vertex float4 shadow_veg_vertex(const device VegVertexGPU* v [[buffer(0)]], constant ShadowUniforms& u [[buffer(1)]],
                                    const device TreeInstanceGPU* inst [[buffer(2)]], constant VegUniforms& vu [[buffer(3)]],
                                    uint vid [[vertex_id]], uint iid [[instance_id]]) {
        TreeInstanceGPU t = inst[iid];
        VegVertexGPU w = v[vid];
        float3 local = float3(w.position);
        float crownW, sz; float2 cs;
        float3 sl = treeShape(local, w.shade < -0.5, float3(t.position), crownW, sz, cs);
        uint th = as_type<uint>(int(floor(t.position.x * 4.0))) * 0x27D4EB2Du ^ as_type<uint>(int(floor(t.position.y * 4.0))) * 0x165667B1u;
        float phase = vegUnit(th) * 6.2831853;
        float3 sw = veg_sway(local, w.sway, vu.timeFade.x, phase, vu.wind, vu.species.y, vu.season.w);
        float3 pw = (sl + sw * float3(crownW, crownW, 1.0)) * t.height + float3(t.position);
        if (w.card > 0.5 && vu.species.z > 0.5 && vegUnit((vid / 6u) * 2654435761u ^ th) < vu.season.y) return float4(0.0, 0.0, 2.0, 1.0);
        return u.lightViewProj * (u.model * float4(pw, 1.0));
    }

    /// Billboard impostor: 6 vertices per tree, no vertex buffer. Draw with instanceCount = trees beyond the card band.
    vertex WorldVarying veg_billboard_vertex(constant WorldUniforms& u [[buffer(1)]], const device TreeInstanceGPU* inst [[buffer(2)]],
                                             constant VegUniforms& vu [[buffer(3)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        TreeInstanceGPU t = inst[iid];
        const float2 corner[6] = { float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1) };
        float2 uv = corner[vid % 6u];
        float crownW, sz; float2 cs;
        float3 hs = treeShape(float3(0.0, 0.0, 1.0), false, float3(t.position), crownW, sz, cs);
        float4 pb = u.model * float4(float3(t.position), 1.0);
        float3 d = normalize(float3(pb.x, pb.y, 0.0) + float3(1e-4, 0.0, 0.0));
        float3 right = float3(-d.y, d.x, 0.0);
        float H = t.height * max(0.5, hs.z);
        float W = H * vu.board.x * crownW;
        float3 p = pb.xyz + right * (uv.x * 2.0 - 1.0) * W + float3(0.0, 0.0, uv.y * H * 1.1);
        float dist = length(pb.xyz);
        float2 rng = veg_rep_range(veg_lod_weights(dist, vu.timeFade), 2.0);
        bool alive = rng.y > rng.x;
        WorldVarying o;
        o.position = alive ? u.viewProj * float4(p, 1.0) : float4(0.0, 0.0, 2.0, 1.0);
        o.rel = p;
        float3 n = normalize(right * (uv.x * 2.0 - 1.0) * 0.8 - d * 0.6 + float3(0.0, 0.0, (uv.y - vu.board.z) * 0.9));
        o.normal = n;
        uint th = as_type<uint>(int(floor(t.position.x * 4.0))) * 0x27D4EB2Du ^ as_type<uint>(int(floor(t.position.y * 4.0))) * 0x165667B1u;
        float tu = vegUnit(th), tv = vegUnit(th ^ 0x9E3779B9u);
        float3 c = float3(t.colour) * (0.85 + 0.3 * uv.y) * (0.82 + 0.36 * tv);
        if (vu.species.z > 0.5) {
            float3 pick = tu < 0.333 ? float3(4.2, 2.6, 0.6) : (tu < 0.666 ? float3(4.0, 1.5, 0.45) : float3(3.2, 0.6, 0.45));
            c *= mix(float3(1.0), pick, vu.season.x * (0.6 + 0.4 * tv));
            c = mix(c, float3(0.05, 0.04, 0.03), 0.55 * vu.season.y);      // bare winter crown reads dark branch-grey
        }
        o.albedo = c;
        o.material = 2.0;
        o.field = saturate(0.25 + 0.6 * uv.y);
        o.local = float3(vu.board.z, vu.board.w, 0.0);
        o.uv = uv;
        o.style = float4(-1.0, rng.x, rng.y, 2.0);
        return o;
    }

    /// Grass blades around the camera. Instances beyond `keep` (hash vs thinning curve) collapse.
    vertex WorldVarying grass_vertex(const device VegVertexGPU* v [[buffer(0)]], constant WorldUniforms& u [[buffer(1)]],
                                     const device GrassInstanceGPU* inst [[buffer(2)]], constant VegUniforms& vu [[buffer(3)]],
                                     uint vid [[vertex_id]], uint iid [[instance_id]]) {
        GrassInstanceGPU g = inst[iid];
        VegVertexGPU w = v[vid];
        float4 pc = u.model * float4(float3(g.position), 1.0);
        float dist = length(pc.xy);
        float r = max(1.0, vu.grass.w);
        float keep = 1.0 - vegSmooth(r * vu.grassParams.x, r, dist);
        float alive = vegUnit(iid * 747796405u + 2891336453u) < keep ? 1.0 : 0.0;
        float cy = cos(g.yaw), sy = sin(g.yaw);
        float3 lp = float3(w.position);
        float3 loc = float3((cy * lp.x - sy * lp.y) * vu.grassParams.z * g.height * 4.0, (sy * lp.x + cy * lp.y) * g.height, lp.z * g.height);
        float phase = vegUnit(iid) * 6.2831853;
        float sway = vu.season.w * min(1.0, vu.wind.z / 14.0) * (0.04 + 0.03 * sin(vu.timeFade.x * 2.4 + phase + dist * 0.15)) * w.sway;
        loc.xy += vu.wind.xy * sway;
        float3 pos = pc.xyz + loc;
        WorldVarying o;
        o.position = alive > 0.5 ? u.viewProj * float4(pos, 1.0) : float4(0.0, 0.0, 2.0, 1.0);
        o.rel = pos;
        float3 n = float3(w.normal);
        o.normal = normalize(float3(cy * n.x - sy * n.y, sy * n.x + cy * n.y, n.z) + float3(0.0, 0.0, 0.6));   // grass lights as a soft ground-facing mass
        float dry = vu.grassParams.y;
        float3 green = vu.grass.xyz * (0.75 + 0.5 * g.tone);
        float3 straw = float3(0.34, 0.27, 0.12) * (0.8 + 0.4 * g.tone);
        o.albedo = mix(green, straw, dry) * (0.55 + 0.45 * w.shade);
        o.material = 2.0;
        o.field = saturate(w.shade);
        o.local = float3(0.0);
        o.uv = float2(0.0);
        o.style = float4(0.0);
        return o;
    }
    """
}
