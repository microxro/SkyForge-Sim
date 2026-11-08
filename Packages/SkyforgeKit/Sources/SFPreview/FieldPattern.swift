// SKYFORGE — Apache-2.0
// Per-pixel field parcels with thin, crisp hedgerows. The terrain mesh carries a per-vertex "field
// weight" (where fields may appear) and both renderers multiply the ground albedo by
// `FieldPattern.factor` per pixel, so parcel borders no longer step or blur at vertex spacing.
// Integer hashing and value noise only, so the Metal shader (WorldShaders) can mirror it exactly.
import Foundation

public struct FieldPattern: Sendable, Equatable {
    public var seed: UInt32
    public var autumn: Bool

    public init(seed: UInt32, autumn: Bool) { self.seed = seed; self.autumn = autumn }

    /// Parcel size along the rotated u, v axes (metres).
    public static let parcelU: Float = 110, parcelV: Float = 170
    /// Half-width of a hedgerow (metres): a 2.4 m dark strip along every parcel border.
    public static let hedgeHalfWidth: Float = 1.2
    static let angle: Float = 0.35

    /// Crop albedos relative to the summer grassland colour the terrain vertices carry (linear ratios of
    /// pasture, hay, wheat, ploughed soil, stubble to sRGB 124/132/70, tempered 15 %), so the factor keeps
    /// the vertex colour's large-scale variation. Muted earth tones only (review: a lime parcel).
    static let summer: [SIMD3<Float>] = [
        SIMD3(0.74, 0.90, 0.80),   // pasture
        SIMD3(1.22, 1.10, 1.28),   // hay
        SIMD3(1.98, 1.41, 1.84),   // ripe wheat
        SIMD3(0.95, 0.60, 1.10),   // ploughed soil
        SIMD3(1.70, 1.28, 2.05),   // stubble
        SIMD3(0.55, 0.70, 0.66),   // dark pasture
        SIMD3(1.32, 0.96, 1.30),   // fallow
    ]
    static let autumnCrops: [SIMD3<Float>] = [
        SIMD3(1.43, 1.03, 1.57), SIMD3(0.78, 0.54, 1.00), SIMD3(0.60, 0.68, 0.82),
        SIMD3(1.22, 0.89, 1.38), SIMD3(0.76, 0.77, 0.95), SIMD3(1.67, 1.21, 2.00),
    ]
    static let hedge = SIMD3<Float>(0.24, 0.30, 0.38)   // dark shrub green

    @inline(__always) static func hash(_ x: Int32, _ y: Int32, _ s: UInt32) -> UInt32 {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343
        h ^= UInt32(bitPattern: y) &* 0xD816_3841
        h ^= s &* 0xCB1A_B31F
        h ^= h >> 13
        h = h &* 0x5BD1_E995
        h ^= h >> 15
        return h
    }

    @inline(__always) static func unit(_ h: UInt32) -> Float { Float(h & 0x00FF_FFFF) / 16_777_216 }

    /// Smooth 2D value noise in [-1, 1).
    static func noise(_ x: Float, _ y: Float, _ s: UInt32) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(fx), iy = Int32(fy)
        var tx = x - fx, ty = y - fy
        tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
        let a = unit(hash(ix, iy, s)), b = unit(hash(ix + 1, iy, s))
        let c = unit(hash(ix, iy + 1, s)), d = unit(hash(ix + 1, iy + 1, s))
        let v = (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
        return v * 2 - 1
    }

    /// Albedo multiplier at world (x, y) metres. `footprint` is the ground size of a pixel (metres):
    /// hedgerows thinner than a pixel fade toward their area-average instead of aliasing.
    public func factor(_ x: Float, _ y: Float, footprint: Float) -> SIMD3<Float> {
        let c = cos(Self.angle), s = sin(Self.angle)
        // Low-frequency warp so borders curve gently like real field boundaries.
        let wu = Self.noise(x / 420 + 7.3, y / 420, seed ^ 0x51) * 22
        let wv = Self.noise(x / 420, y / 420 - 9.1, seed ^ 0xA3) * 22
        let u = c * x + s * y + wu, v = -s * x + c * y + wv
        let fu = u / Self.parcelU, fv = v / Self.parcelV
        let iu = fu.rounded(.down), iv = fv.rounded(.down)
        let h = Self.hash(Int32(iu), Int32(iv), seed)
        let crops = autumn ? Self.autumnCrops : Self.summer
        var col = crops[Int(h % UInt32(crops.count))]
        // Gentle in-field gradient (crop rows cannot be represented; a tonal drift reads as tilth).
        let tu = fu - iu, tv = fv - iv
        let along = (h >> 24) & 1 == 0 ? tu : tv
        col *= 0.95 + 0.08 * along
        // Distance to the parcel border in metres; crisp hedgerow strip, anti-aliased by footprint.
        let edge = min(tu * Self.parcelU, (1 - tu) * Self.parcelU, tv * Self.parcelV, (1 - tv) * Self.parcelV)
        let fp = max(0.05, footprint)
        let hw = Self.hedgeHalfWidth
        let cover = 1 - min(1, max(0, (edge - hw) / fp + 0.5))     // pixel coverage of the strip
        let strength = min(1, 2 * hw / fp)                           // thinner than a pixel → area-average
        // Hedges break up: gaps where the noise is low, so lines are not ruled.
        let gaps = Self.noise(u / 18, v / 18, seed ^ 0x77) > -0.55 ? Float(1) : 0
        let hedgeAmount = cover * strength * gaps
        return col + (Self.hedge - col) * hedgeAmount
    }
}
