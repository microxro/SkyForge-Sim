// SKYFORGE — Apache-2.0
// Suburban parcel fabric for the terrain shader: kerb, planting strip, sidewalk with expansion joints, driveways
// and per-lot lawns, generated from the road-frame mask that `SuburbMask.build` rasterises from Overture land use
// and OSM roads. Static functions only (no entry points, no dependency on WorldShaders helpers), meant to be
// spliced into the world library before `world_fragment` and called on near ground within ~2 km:
//
//     float4 smL = suburbMask.sample(imgSampler, nuv, level(0.0));           // texture(9), RGBA8 from SuburbMask, bilinear: R, B
//     float4 smN = suburbMask.read(uint2(nuv * float2(suburbMask.get_width(), suburbMask.get_height())));  // nearest: G, A
//     SuburbSurface s = suburbParcels(smL, smN, photoW, footprint, dist, albedo);   // albedo: the macro/lawn colour
//     albedo = mix(albedo, s.albedo, s.weight);  groundRough = mix(groundRough, s.roughness, s.weight);
//
// See docs/rounds/ROUND2.md.

public enum SuburbShaders {
    public static let source = """
    struct SuburbSurface {
        float3 albedo;      // linear albedo to replace the photo ground with
        float roughness;    // 0.55 sealed concrete … 1.0 grass
        float weight;       // 0…1: how much of the photo to replace (0 outside residential frontage or beyond 2 km)
        float paved;        // 0…1 concrete/asphalt coverage (for the normal/ripple path)
    };

    static float sub_hash(float2 p) {
        p = fract(p * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return fract((p.x + p.y) * p.x);
    }
    /// Antialiased 0…1 box between a and b along x with half-pixel width `aa`.
    static float sub_band(float a, float b, float x, float aa) {
        return smoothstep(a - aa, a + aa, x) * (1.0 - smoothstep(b - aa, b + aa, x));
    }

    /// `mask`: bilinear RGBA8 sample of the suburb mask (R parcel weight, B distance/60 m: both blend safely).
    /// `maskN`: NEAREST-texel sample of the same mask (G road tangent angle/π wraps 0↔π and A is a road class, so
    /// neither may be interpolated; B/R are not read from it). A is 0.25 m units of half width. `w`: world position in region metres. `fp`: pixel footprint (m). `dist`: camera distance (m).
    /// `lawn`: the macro lawn colour to tint per lot (the photo's coarse mean, not its pixels).
    static SuburbSurface suburbParcels(float4 mask, float4 maskN, float2 w, float fp, float dist, float3 lawn) {
        SuburbSurface o;
        o.albedo = lawn; o.roughness = 1.0; o.paved = 0.0;
        o.weight = mask.r * (1.0 - smoothstep(1500.0, 2000.0, dist));
        if (o.weight <= 0.001) { o.weight = 0.0; return o; }

        float ang = maskN.g * 3.14159265;
        float2 t = float2(cos(ang), sin(ang));
        float s = dot(w, t);                         // along the road
        float d = mask.b * 60.0;                     // from the centreline
        float e = d - maskN.a * 63.75;                // beyond the kerb
        float aa = max(fp, 0.04);

        // Lots: 14–22 m wide frontages, lot index along the road decided by a hash of the road cell so
        // neighbouring blocks do not line up. Per-lot random: tone, driveway position and width, setback.
        float lotW = 15.0 + 5.0 * sub_hash(float2(maskN.a * 255.0, 7.0));   // per road class: no jump at arbitrary world cells
        float li = floor(s / lotW);
        float lu = s - li * lotW;                    // 0…lotW inside the lot
        float h0 = sub_hash(float2(li, 3.0 + maskN.a * 255.0));   // not keyed on `side`: a 40 m stripe through a lot would cut it in two tones
        float h1 = sub_hash(float2(li + 11.0, h0 * 91.0));
        float h2 = sub_hash(float2(li - 5.0, h1 * 57.0));

        // Bands beyond the kerb (metres): gutter 0–0.35, planting strip 0.35–1.9, sidewalk 1.9–3.4, lawn beyond.
        float gutter = sub_band(0.0, 0.35, e, aa);
        // The carriageway (e < 0) belongs to the road/photo layer: do not paint lawn over it.
        o.weight *= smoothstep(-aa, aa, e);
        float strip = sub_band(0.35, 1.9, e, aa);
        float walk = sub_band(1.9, 3.4, e, aa);
        // Driveway: 2.8–3.8 m wide strip from the kerb to a 6–11 m setback, centred somewhere on the lot's frontage;
        // about one lot in eight has none (corner lots, alley access).
        float dw = 2.8 + 1.0 * h1;
        float dc = lotW * (0.22 + 0.56 * h0);
        float driveway = (h2 > 0.12 ? 1.0 : 0.0) * sub_band(dc - dw * 0.5, dc + dw * 0.5, lu, aa) * sub_band(0.0, 6.0 + 5.0 * h2, e, aa);
        // Expansion joints every 1.5 m across the sidewalk, 2.5 m across the driveway, fading as the cells shrink.
        float joint = (1.0 - smoothstep(0.012, 0.012 + aa, abs(fract(s / 1.5 + 0.5) - 0.5) * 1.5)) * walk * (1.0 - driveway);
        joint = max(joint, (1.0 - smoothstep(0.012, 0.012 + aa, abs(fract(e / 2.5 + 0.5) - 0.5) * 2.5)) * driveway);
        joint *= saturate(1.0 - fp / 0.6);
        // Lot boundary: a faint fence/hedge line a few metres behind the sidewalk, 0.25 m wide.
        float lotLine = sub_band(-0.12, 0.12, min(lu, lotW - lu), aa) * smoothstep(3.6, 4.2, e) * (1.0 - smoothstep(30.0, 38.0, e));

        // Materials (linear albedo).
        float3 concrete = float3(0.34, 0.33, 0.31) * (0.9 + 0.2 * h1);                 // sidewalk / driveway: pale
        float3 driveCol = h2 > 0.55 ? concrete * 1.05 : float3(0.075, 0.075, 0.08);    // concrete or asphalt
        float3 gutterCol = float3(0.20, 0.20, 0.19);
        float3 lotLawn = lawn * (0.90 + 0.20 * h0) * mix(float3(1.0), float3(1.10, 1.02, 0.82), saturate(h2 - 0.6) * 1.5);
        float3 stripLawn = lotLawn * float3(0.92, 0.98, 0.90);
        float3 c = lotLawn;
        c = mix(c, stripLawn, strip);
        c = mix(c, gutterCol, gutter);
        c = mix(c, concrete, walk);
        c = mix(c, driveCol, driveway);
        c *= 1.0 - 0.28 * joint;
        c *= 1.0 - 0.10 * lotLine;

        // Detail fades once a lot is a few pixels: beyond ~6 m footprints the parcel mean replaces the structure.
        float detail = 1.0 - smoothstep(1.5, 6.0, fp);
        float pavedFrac = max(max(walk, driveway), gutter);
        float3 mean = lotLawn * 0.89 + concrete * 0.08 + gutterCol * 0.03;
        o.albedo = mix(mean, c, detail);
        o.paved = pavedFrac * detail;
        o.roughness = mix(1.0, 0.72, o.paved);
        // Back yards beyond ~38 m from a road: stop imposing structure, keep only the per-lot lawn tone.
        float back = smoothstep(38.0, 52.0, e);
        o.albedo = mix(o.albedo, lotLawn, back);
        o.paved *= 1.0 - back; o.roughness = mix(o.roughness, 1.0, back);
        return o;
    }
    """
}
