// SKYFORGE — Apache-2.0
// Round 5 vegetation (CPU side): five extra tree species grown from branch skeletons with leaf cards,
// a mid LOD of fewer branches and cards, a billboard impostor layout for the far LOD with a dithered
// cross-fade, wind sway (the reference the MSL in VegetationShaders mirrors), seasonal tint, and
// near-camera grass scatter plus a blade mesh. Pure Swift and deterministic, so Linux CI tests it.
// Species indices continue after TreeModels (0…4): 5 birch, 6 cypress, 7 willow, 8 acacia, 9 palm.
import Foundation
import SFMath

// MARK: Tier knobs

public enum VegetationTier: Int, Sendable, CaseIterable {
    case low, medium, high, ultra

    /// Distance (m, camera to tree) where the full-detail mesh starts handing over to the card mesh.
    public var cardStart: Float { [180, 260, 380, 520][rawValue] }
    /// Distance where the card mesh starts handing over to the billboard impostor.
    public var billboardStart: Float { [500, 800, 1_300, 2_000][rawValue] }
    /// Width (m) of each cross-fade band.
    public var fadeWidth: Float { [60, 90, 140, 200][rawValue] }
    /// Distance beyond which trees are not drawn at all.
    public var farCull: Float { [2_500, 4_000, 6_500, 10_000][rawValue] }
    /// Grass radius around the camera (m); 0 turns ground cover off.
    public var grassRadius: Float { [0, 35, 60, 90][rawValue] }
    /// Blades per square metre inside the grass radius.
    public var grassDensity: Float { [0, 18, 40, 80][rawValue] }
    /// Leaf cards per branch tip at the full mesh.
    public var cardsPerTip: Int { [2, 3, 4, 5][rawValue] }
    public var swayEnabled: Bool { self != .low }
    /// Impostor views around the tree (azimuth steps).
    public var impostorViews: Int { [4, 8, 8, 12][rawValue] }
}

// MARK: Vertex

public struct VegVertex: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    /// −1 bark, otherwise 0 (deep in the crown) … 1 (open to the sky), as `TreeVertex.shade`.
    public var shade: Float
    /// Wind response 0 (rooted) … 1 (leaf tip); the shader scales sway by it.
    public var sway: Float
    /// 1 for leaf-card vertices (alpha-cut by the shader's leaf texture), 0 for solid geometry.
    public var card: Float
    public var uv: SIMD2<Float>
}

public enum SpeciesKind: Int, Sendable, CaseIterable {
    case birch = 5, cypress, willow, acacia, palm

    public var deciduous: Bool { self == .birch || self == .willow || self == .acacia }
    /// Bark colour (linear-ish albedo); birch is pale.
    public var barkColour: SIMD3<Float> {
        switch self {
        case .birch: return SIMD3(0.55, 0.52, 0.46)
        case .cypress: return SIMD3(0.07, 0.05, 0.035)
        case .willow: return SIMD3(0.08, 0.065, 0.045)
        case .acacia: return SIMD3(0.10, 0.075, 0.05)
        case .palm: return SIMD3(0.16, 0.12, 0.08)
        }
    }
    /// Leaf albedo baseline for the instance colour (the app may override per region).
    public var leafColour: SIMD3<Float> {
        switch self {
        case .birch: return SIMD3(0.16, 0.30, 0.07)
        case .cypress: return SIMD3(0.05, 0.12, 0.06)
        case .willow: return SIMD3(0.19, 0.30, 0.09)
        case .acacia: return SIMD3(0.20, 0.27, 0.08)
        case .palm: return SIMD3(0.10, 0.25, 0.07)
        }
    }
    /// Gust stiffness: higher sways less.
    public var stiffness: Float {
        switch self {
        case .cypress: return 2.2
        case .acacia: return 1.5
        case .birch: return 0.9
        case .willow: return 0.6
        case .palm: return 0.8
        }
    }
}

// MARK: Models

public enum VegetationModels {
    public static let firstVariant = 5
    public static let variantCount = 5
    /// Total species across TreeModels and these.
    public static let totalSpecies = TreeModels.variantCount + variantCount

    /// Deterministic species for a tree. `climate`: 0 temperate, 1 dry/savanna, 2 tropical/coastal.
    public static func species(x: Float, y: Float, climate: Int) -> SpeciesKind {
        let h = Hash.int(Int((x * 3).rounded()), Int((y * 3).rounded()), seed: 0x7EE9_77)
        switch climate {
        case 1: return h % 3 == 0 ? .cypress : .acacia
        case 2: return h % 4 == 0 ? .willow : .palm
        default: return [SpeciesKind.birch, .willow, .cypress][Int(h % 3)]
        }
    }

    struct Spec {
        var trunkTop: Float, trunkR0: Float, trunkR1: Float
        var branches: Int, reach: Float, elevation: Float, droop: Float
        var cardSize: Float, crownCentre: SIMD3<Float>, crownRadius: Float
    }

    static func spec(_ k: SpeciesKind) -> Spec {
        switch k {
        case .birch: return Spec(trunkTop: 0.42, trunkR0: 0.020, trunkR1: 0.012, branches: 9, reach: 0.26, elevation: 0.75, droop: 0.15,
                                 cardSize: 0.085, crownCentre: SIMD3(0, 0, 0.66), crownRadius: 0.30)
        case .cypress: return Spec(trunkTop: 0.18, trunkR0: 0.028, trunkR1: 0.020, branches: 12, reach: 0.12, elevation: 1.25, droop: 0,
                                   cardSize: 0.075, crownCentre: SIMD3(0, 0, 0.58), crownRadius: 0.16)
        case .willow: return Spec(trunkTop: 0.30, trunkR0: 0.034, trunkR1: 0.022, branches: 8, reach: 0.34, elevation: 0.65, droop: 1.1,
                                  cardSize: 0.10, crownCentre: SIMD3(0, 0, 0.58), crownRadius: 0.42)
        case .acacia: return Spec(trunkTop: 0.52, trunkR0: 0.026, trunkR1: 0.016, branches: 6, reach: 0.46, elevation: 0.28, droop: -0.1,
                                  cardSize: 0.11, crownCentre: SIMD3(0, 0, 0.80), crownRadius: 0.50)
        case .palm: return Spec(trunkTop: 0.78, trunkR0: 0.024, trunkR1: 0.015, branches: 0, reach: 0.34, elevation: 0.5, droop: 0.9,
                                cardSize: 0.16, crownCentre: SIMD3(0, 0, 0.88), crownRadius: 0.32)
        }
    }

    struct Builder {
        var out: [VegVertex] = []
        var rng: SplitMix64
        mutating func f() -> Float { Float(Hash.unit(rng.next())) }

        static func norm(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
            return l > 1e-6 ? v / l : SIMD3(0, 0, 1)
        }
        static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }

        /// Tapered tube between two points (bark).
        mutating func tube(_ a: SIMD3<Float>, _ b: SIMD3<Float>, r0: Float, r1: Float, sides: Int, swayA: Float, swayB: Float) {
            let axis = Builder.norm(b - a)
            let ref: SIMD3<Float> = abs(axis.z) > 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)
            let u = Builder.norm(Builder.cross(axis, ref)), v = Builder.cross(axis, u)
            func vert(_ k: Int, _ end: Bool) -> VegVertex {
                let ang = Float(k % sides) / Float(sides) * 2 * .pi
                let d = u * cos(ang) + v * sin(ang)
                let p = (end ? b + d * r1 : a + d * r0)
                return VegVertex(position: p, normal: d, shade: -1, sway: end ? swayB : swayA, card: 0,
                                 uv: SIMD2(Float(k) / Float(sides), end ? 1 : 0))
            }
            for k in 0..<sides {
                let a0 = vert(k, false), a1 = vert(k + 1, false), b0 = vert(k, true), b1 = vert(k + 1, true)
                out += [a0, a1, b1, a0, b1, b0]
            }
        }

        /// A crossed pair of quads (a leaf card cluster) at `c`, normals blended outward from the crown.
        mutating func cards(at c: SIMD3<Float>, size: Float, crown: SIMD3<Float>, crownR: Float, bottom: Float, top: Float, count: Int, swayW: Float) {
            for _ in 0..<count {
                let yaw = f() * 2 * .pi, tilt = (f() - 0.5) * 1.0
                let right = SIMD3<Float>(cos(yaw), sin(yaw), 0)
                let up = Builder.norm(SIMD3<Float>(-sin(yaw) * tilt * 0.5, cos(yaw) * tilt * 0.5, 1))
                let jitter = SIMD3<Float>(f() - 0.5, f() - 0.5, f() - 0.5)
                let ctr = c + jitter * size * 1.2
                let out0 = Builder.norm(ctr - crown)
                let facing = Builder.norm(Builder.cross(right, up))
                let n = Builder.norm(out0 * 0.6 + facing * 0.4)
                let wl = ((ctr - crown) * (ctr - crown)).sum().squareRoot()
                let outer = min(1, wl / max(1e-4, crownR))
                let height = max(0, min(1, (ctr.z - bottom) / max(1e-4, top - bottom)))
                let shade = max(0, min(1, 0.2 + 0.5 * outer * outer + 0.4 * height))
                func q(_ sx: Float, _ sy: Float, _ ux: Float, _ uy: Float) -> VegVertex {
                    VegVertex(position: ctr + right * sx * size + up * sy * size, normal: n, shade: shade, sway: swayW, card: 1, uv: SIMD2(ux, uy))
                }
                let a = q(-1, -1, 0, 0), b = q(1, -1, 1, 0), cc = q(1, 1, 1, 1), d = q(-1, 1, 0, 1)
                out += [a, b, cc, a, cc, d]
                // Second quad rotated 90 degrees about the up axis (crossed cards read as volume from any side).
                let right2 = Builder.cross(up, right)
                func q2(_ sx: Float, _ sy: Float, _ ux: Float, _ uy: Float) -> VegVertex {
                    VegVertex(position: ctr + right2 * sx * size + up * sy * size, normal: n, shade: shade, sway: swayW, card: 1, uv: SIMD2(ux, uy))
                }
                let a2 = q2(-1, -1, 0, 0), b2 = q2(1, -1, 1, 0), c2 = q2(1, 1, 1, 1), d2 = q2(-1, 1, 0, 1)
                out += [a2, b2, c2, a2, c2, d2]
            }
        }
    }

    /// `detail` 0 = full (branches, sub-branches, many cards), 1 = card LOD (primary branches, fewer cards).
    public static func build(_ kind: SpeciesKind, detail: Int, tier: VegetationTier = .high) -> [VegVertex] {
        let s = spec(kind)
        var b = Builder(rng: SplitMix64(seed: 0x56E6_0000 + UInt64(kind.rawValue) * 31 + UInt64(detail)))
        let full = detail == 0
        let sides = full ? 5 : 3
        let perTip = full ? tier.cardsPerTip : max(1, tier.cardsPerTip / 2)
        let bottom = s.trunkTop * 0.5, top: Float = 1.0
        let lean = SIMD3<Float>((b.f() - 0.5) * 0.04, (b.f() - 0.5) * 0.04, 0)
        let trunkTip = SIMD3<Float>(lean.x, lean.y, s.trunkTop)
        if kind == .palm {
            // Curved trunk in three segments, then a rosette of drooping fronds (long cards).
            var prev = SIMD3<Float>(0, 0, -0.03)
            for i in 1...3 {
                let t = Float(i) / 3
                let p = SIMD3<Float>(0.07 * t * t, 0.03 * t * t, -0.03 + (s.trunkTop + 0.03) * t)
                b.tube(prev, p, r0: s.trunkR0 * (1 - 0.3 * (t - 0.33)), r1: s.trunkR0 * (1 - 0.3 * t) , sides: sides, swayA: Float(i - 1) / 3, swayB: t)
                prev = p
            }
            let crown = prev
            let fronds = full ? 11 : 7
            for k in 0..<fronds {
                let az = Float(k) / Float(fronds) * 2 * .pi + b.f() * 0.3
                let dir = SIMD3<Float>(cos(az), sin(az), 0)
                let len = s.reach * (0.85 + 0.3 * b.f())
                // Three segments per frond arcing upward then down.
                var p0 = crown
                for seg in 0..<3 {
                    let t0 = Float(seg) / 3, t1 = Float(seg + 1) / 3
                    func pt(_ t: Float) -> SIMD3<Float> { crown + dir * len * t + SIMD3<Float>(0, 0, len * (0.55 * t - s.droop * 0.5 * t * t)) }
                    let p1 = pt(t1)
                    let mid = (p0 + p1) * 0.5
                    let nrm = Builder.norm(SIMD3<Float>(0, 0, 1) * 0.7 + dir * 0.3)
                    let along = Builder.norm(p1 - p0)
                    let side = Builder.norm(Builder.cross(along, nrm))
                    let w = s.cardSize * (0.6 + 0.5 * (1 - abs(t0 + t1 - 1)))
                    let hl = ((p1 - p0) * (p1 - p0)).sum().squareRoot() * 0.5
                    func v(_ a: Float, _ c: Float, _ ux: Float, _ uy: Float) -> VegVertex {
                        VegVertex(position: mid + side * a * w + along * c * hl, normal: nrm, shade: 0.55 + 0.4 * t1, sway: 0.5 + 0.5 * t1, card: 1, uv: SIMD2(ux, uy))
                    }
                    b.out += [v(-1, -1, 0, t0), v(1, -1, 1, t0), v(1, 1, 1, t1), v(-1, -1, 0, t0), v(1, 1, 1, t1), v(-1, 1, 0, t1)]
                    p0 = p1
                }
            }
            return normalised(b.out)
        }

        // Trunk in two segments with a slight bend.
        let mid = SIMD3<Float>(lean.x * 0.3 + (b.f() - 0.5) * 0.02, lean.y * 0.3, s.trunkTop * 0.5)
        b.tube(SIMD3(0, 0, -0.03), mid, r0: s.trunkR0, r1: (s.trunkR0 + s.trunkR1) * 0.5, sides: sides, swayA: 0, swayB: 0.15)
        b.tube(mid, trunkTip, r0: (s.trunkR0 + s.trunkR1) * 0.5, r1: s.trunkR1, sides: sides, swayA: 0.15, swayB: 0.3)

        let nBranch = full ? s.branches : max(3, s.branches / 2)
        for i in 0..<nBranch {
            let frac = Float(i) / Float(max(1, nBranch - 1))
            let az = Float(i) * 2.399_963 + b.f() * 0.5                       // golden angle: even spread
            let el = s.elevation * (0.8 + 0.4 * b.f()) * (0.7 + 0.3 * (1 - frac))
            let baseZ = s.trunkTop * (0.55 + 0.45 * frac)
            let base = SIMD3<Float>(lean.x * frac, lean.y * frac, baseZ)
            let len = s.reach * (1 - 0.35 * frac) * (0.85 + 0.3 * b.f())
            let ce = cos(min(1.4, el)), se = sin(min(1.4, el))
            let dir = SIMD3<Float>(cos(az) * ce, sin(az) * ce, se)
            let midP = base + dir * len * 0.5
            let tip = base + dir * len + SIMD3<Float>(0, 0, -s.droop * len * 0.45)
            let w0 = 0.22 + 0.2 * frac
            b.tube(base, midP, r0: s.trunkR1 * 0.55, r1: s.trunkR1 * 0.4, sides: sides, swayA: w0, swayB: w0 + 0.15)
            b.tube(midP, tip, r0: s.trunkR1 * 0.4, r1: s.trunkR1 * 0.15, sides: sides, swayA: w0 + 0.15, swayB: 0.6)
            b.cards(at: tip, size: s.cardSize, crown: s.crownCentre, crownR: s.crownRadius, bottom: bottom, top: top, count: perTip, swayW: 1)
            if full {
                // Two twigs off the outer half, each carrying its own card cluster.
                for side in [Float(-1), 1] {
                    let a2 = az + side * (0.7 + 0.4 * b.f())
                    let d2 = SIMD3<Float>(cos(a2) * ce, sin(a2) * ce, se * 0.8)
                    let t0 = base + dir * len * 0.6
                    let t1 = t0 + d2 * len * 0.45 + SIMD3<Float>(0, 0, -s.droop * len * 0.2)
                    b.tube(t0, t1, r0: s.trunkR1 * 0.18, r1: s.trunkR1 * 0.08, sides: 3, swayA: 0.5, swayB: 0.75)
                    b.cards(at: t1, size: s.cardSize * 0.9, crown: s.crownCentre, crownR: s.crownRadius, bottom: bottom, top: top, count: max(1, perTip - 1), swayW: 1)
                }
            }
        }
        // A core cluster so the crown has no see-through hole in the middle.
        b.cards(at: s.crownCentre, size: s.cardSize * 1.4, crown: s.crownCentre, crownR: s.crownRadius, bottom: bottom, top: top, count: full ? 4 : 2, swayW: 0.8)
        return normalised(b.out)
    }

    /// Scale so the highest vertex sits at z = 1 (unit-height convention of TreeModels).
    static func normalised(_ v: [VegVertex]) -> [VegVertex] {
        let top = v.map { $0.position.z }.max() ?? 1
        guard top > 1e-4 else { return v }
        let k = 1 / top
        return v.map { var o = $0; o.position *= k; return o }
    }

    /// Triangle lists for all five species: [full, card LOD].
    public static func buildAll(tier: VegetationTier = .high) -> (full: [[VegVertex]], card: [[VegVertex]]) {
        (SpeciesKind.allCases.map { build($0, detail: 0, tier: tier) }, SpeciesKind.allCases.map { build($0, detail: 1, tier: tier) })
    }
}

// MARK: LOD cross-fade

public struct LODWeights: Sendable, Equatable {
    /// Share of the tree drawn as each representation, summing to 1.
    public var full: Float, card: Float, billboard: Float
}

public enum VegetationLOD {
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / max(1e-4, b - a))); return t * t * (3 - 2 * t)
    }
    /// Weights at `distance` metres. Each band is centred on its start distance (`start ± width/2`).
    public static func weights(distance d: Float, tier: VegetationTier) -> LODWeights {
        let w = tier.fadeWidth * 0.5
        let toCard = smooth(tier.cardStart - w, tier.cardStart + w, d)
        let toBoard = smooth(tier.billboardStart - w, tier.billboardStart + w, d)
        return LODWeights(full: 1 - toCard, card: toCard * (1 - toBoard), billboard: toBoard)
    }
    /// Screen-space dither value in [0,1) (interleaved gradient noise); the shader uses the same formula.
    public static func dither(x: Float, y: Float) -> Float {
        let v = 52.982_918_9 * (0.067_110_56 * x + 0.005_837_15 * y).truncatingRemainder(dividingBy: 1)
        return v - v.rounded(.down)
    }
    /// A fragment of a representation with share `weight` is kept when dither < weight; the representations'
    /// cumulative thresholds are complementary, so exactly one keeps each pixel and nothing blends or pops.
    public static func keeps(weights w: LODWeights, rep: Int, dither n: Float) -> Bool {
        switch rep {
        case 0: return n < w.full
        case 1: return n >= w.full && n < w.full + w.card
        default: return n >= w.full + w.card
        }
    }
}

// MARK: Billboard impostor

public struct ImpostorLayout: Sendable {
    public var views: Int
    public init(tier: VegetationTier) { views = tier.impostorViews }

    /// Atlas slice (species × views) for a species and azimuth step.
    public func slice(species: Int, view: Int) -> Int { species * views + ((view % views) + views) % views }

    /// The two nearest bake views to a camera-to-tree bearing (radians) and the blend toward the second.
    public func views(forBearing a: Float) -> (first: Int, second: Int, blend: Float) {
        let step = 2 * Float.pi / Float(views)
        var t = a / step
        t -= (t / Float(views)).rounded(.down) * Float(views)
        let i = Int(t.rounded(.down)) % views
        return (i, (i + 1) % views, t - t.rounded(.down))
    }

    /// Bake camera for a view: orthographic, looking horizontally at the tree from azimuth `view`.
    public func bakeAxes(view: Int) -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let az = Float(view) / Float(views) * 2 * .pi
        let fwd = SIMD3<Float>(-cos(az), -sin(az), 0)
        return (SIMD3(-sin(az), cos(az), 0), SIMD3(0, 0, 1), fwd)
    }

    /// Billboard size (world units per unit tree height) the quad must cover: width 2 × crown radius, height 1.1.
    public static func quadHalfSize(species: Int) -> SIMD2<Float> {
        if species >= 5, let k = SpeciesKind(rawValue: species) { let r = VegetationModels.spec(k).crownRadius; return SIMD2(max(0.2, r * 1.15), 0.55) }
        return SIMD2(species == 4 ? 0.55 : 0.45, 0.55)
    }
}

// MARK: Wind

public struct WindState: Sendable, Equatable {
    public var direction: SIMD2<Float>   // unit, direction the wind blows toward
    public var speed: Float              // m/s
    public var gustiness: Float          // 0…1
    public init(direction: SIMD2<Float> = SIMD2(1, 0), speed: Float = 5, gustiness: Float = 0.3) {
        self.direction = direction; self.speed = speed; self.gustiness = gustiness
    }
}

public enum WindSway {
    /// Horizontal offset (tree-local units, fractions of tree height) of a vertex. `local` is the unit-height
    /// vertex, `weight` its VegVertex.sway, `treeHeight` metres, `phase` a per-tree 0…2π. The MSL
    /// `veg_sway` computes the same thing.
    public static func offset(local: SIMD3<Float>, weight: Float, treeHeight: Float, time: Float, phase: Float,
                              wind: WindState, stiffness: Float) -> SIMD3<Float> {
        let bend = max(0, local.z)
        let strength = min(1, wind.speed / 20) / max(0.3, stiffness)
        // Trunk bend: slow, scales with height squared; the gust term varies across trees by phase.
        let slow = sin(time * 0.9 + phase) * 0.5 + 0.5 + wind.gustiness * sin(time * 0.37 + phase * 1.7)
        let base = 0.035 * strength * bend * bend * (0.55 + slow)
        // Leaf flutter: fast and small, decorrelated per vertex by position.
        let vp = (local.x + local.y * 1.7 + local.z * 2.3) * 17
        let flutter = 0.006 * strength * weight * sin(time * (5 + wind.speed * 0.35) + vp + phase)
        let along = base * (0.4 + weight)
        let d = SIMD2(wind.direction.x, wind.direction.y)
        return SIMD3(d.x * (along + flutter), d.y * (along + flutter), -abs(along) * 0.06)
    }
}

// MARK: Season

public struct SeasonState: Sendable, Equatable {
    /// 0…1: how far leaves have turned autumn colours.
    public var autumn: Float
    /// 0…1: fraction of deciduous foliage dropped (1 = bare winter).
    public var leafDrop: Float
    /// Spring flush: brighter, yellower green.
    public var spring: Float
}

public enum VegetationSeason {
    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
    /// `dayOfYear` 1…366, `latitude` degrees. Tropics (|lat| < 15) stay green; the southern hemisphere is shifted half a year.
    public static func state(dayOfYear: Float, latitude: Float) -> SeasonState {
        let strength = max(0, min(1, (abs(latitude) - 15) / 30))
        let theta = 2 * Float.pi * (dayOfYear - 200) / 365 + (latitude < 0 ? Float.pi : 0)
        let warm = cos(theta)           // 1 at the summer peak
        let falling = sin(theta) > 0    // after the peak
        let cool = smooth(0.55, -0.1, warm)
        let autumn = falling ? cool * strength : 0
        let drop = smooth(-0.05, -0.8, warm) * strength
        let spring: Float = falling ? 0 : (1 - smooth(-0.6, 0.4, warm)) * (1 - drop) * strength
        return SeasonState(autumn: autumn, leafDrop: drop, spring: spring)
    }

    /// Multiplier on leaf albedo for a tree (`treeHash` in [0,1)): autumn palette per tree, spring lift.
    public static func leafTint(_ s: SeasonState, treeHash: Float, deciduous: Bool) -> SIMD3<Float> {
        guard deciduous else { return SIMD3(1, 1, 1) }
        let palette: [SIMD3<Float>] = [SIMD3(4.2, 2.6, 0.6), SIMD3(4.0, 1.5, 0.45), SIMD3(3.2, 0.6, 0.45)]   // vs green leaf
        let pick = palette[min(2, Int(treeHash * 3))]
        let a = s.autumn * (0.6 + 0.4 * treeHash)
        var t = SIMD3<Float>(1, 1, 1) * (1 - a) + pick * a
        t = t * (1 - 0.3 * s.spring) + SIMD3(1.15, 1.2, 0.8) * (0.3 * s.spring)
        return t
    }

    /// True when a leaf card with per-card hash `h` in [0,1) has fallen at this season.
    public static func cardDropped(_ s: SeasonState, hash h: Float) -> Bool { h < s.leafDrop }
}

// MARK: Ground cover

public struct GrassBlade: Sendable, Equatable {
    public var x: Float, y: Float, height: Float, yaw: Float, tone: Float
}

public enum GroundCover {
    /// One blade: 3 segments tapering to a tip, local space (x across, z up 0…1), uv.y = height fraction.
    public static func bladeMesh() -> [VegVertex] {
        let widths: [Float] = [0.5, 0.42, 0.28, 0.0]
        let bend: [Float] = [0, 0.04, 0.14, 0.32]
        func v(_ i: Int, _ side: Float) -> VegVertex {
            let z = Float(i) / 3
            return VegVertex(position: SIMD3(side * widths[i] * 0.5, bend[i], z), normal: SIMD3(0, -1, 0.35), shade: 0.4 + 0.6 * z,
                             sway: z * z, card: 0, uv: SIMD2(side * 0.5 + 0.5, z))
        }
        var out: [VegVertex] = []
        for i in 0..<3 {
            out += [v(i, -1), v(i, 1), v(i + 1, 1)]
            if i < 2 { out += [v(i, -1), v(i + 1, 1), v(i + 1, -1)] }
        }
        return out
    }

    /// Blades in the square cell (cx, cy) of `cellSize` metres, deterministic. `exclude` rejects roads,
    /// buildings and water; `density` is blades per m².
    public static func scatter(cellX cx: Int, cellY cy: Int, cellSize: Float, density: Float, seed: UInt64 = 0x6A55,
                               exclude: (Float, Float) -> Bool = { _, _ in false }) -> [GrassBlade] {
        let n = Int((density * cellSize * cellSize).rounded())
        guard n > 0 else { return [] }
        var rng = SplitMix64(seed: Hash.int(cx, cy, seed: seed))
        var out: [GrassBlade] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let x = (Float(cx) + Float(Hash.unit(rng.next()))) * cellSize
            let y = (Float(cy) + Float(Hash.unit(rng.next()))) * cellSize
            let yaw = Float(Hash.unit(rng.next())) * 2 * .pi
            let h = 0.12 + 0.25 * Float(Hash.unit(rng.next()))
            let tone = Float(Hash.unit(rng.next()))
            if exclude(x, y) { continue }
            out.append(GrassBlade(x: x, y: y, height: h, yaw: yaw, tone: tone))
        }
        return out
    }

    /// Share of blades kept at `distance` (thinning toward the radius so the edge never pops).
    public static func keepFraction(distance d: Float, tier: VegetationTier) -> Float {
        let r = tier.grassRadius
        guard r > 0 else { return 0 }
        return 1 - VegetationSeason.smooth(r * 0.55, r, d)
    }
}

// MARK: GPU packing

/// Tightly packed GPU vertex: 11 Floats, laid out exactly like the MSL `VegVertexGPU`
/// (packed_float3 position, packed_float3 normal, shade, sway, card, packed_float2 uv) = 44 bytes.
/// `VegVertex` itself holds SIMD3 fields (16 B aligned, 48+ B stride in memory) and must never be uploaded raw.
public struct VegVertexGPU: Sendable, Equatable {
    public var px, py, pz, nx, ny, nz, shade, sway, card, u, v: Float
    public init(_ s: VegVertex) {
        px = s.position.x; py = s.position.y; pz = s.position.z
        nx = s.normal.x; ny = s.normal.y; nz = s.normal.z
        shade = s.shade; sway = s.sway; card = s.card; u = s.uv.x; v = s.uv.y
    }
}

public extension VegVertex {
    /// Bytes per vertex in the `VegVertexGPU` MSL struct; derived from the Swift packed struct so they cannot drift.
    static var gpuStride: Int { MemoryLayout<VegVertexGPU>.stride }
    /// Floats per vertex in the packed layout.
    static let gpuFloatCount = 11
    /// position(3) normal(3) shade sway card uv(2).
    var gpuFloats: [Float] { [position.x, position.y, position.z, normal.x, normal.y, normal.z, shade, sway, card, uv.x, uv.y] }

    /// Typed upload array (stride 44). Prefer this over `gpuBuffer`.
    static func gpuVertices(_ vertices: [VegVertex]) -> [VegVertexGPU] { vertices.map(VegVertexGPU.init) }

    static func gpuBuffer(_ vertices: [VegVertex]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(vertices.count * gpuFloatCount)
        for v in vertices { out += v.gpuFloats }
        return out
    }
}
