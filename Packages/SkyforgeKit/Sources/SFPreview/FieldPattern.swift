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
    static let hedge = SIMD3<Float>(0.46, 0.56, 0.52)   // mid-dark shrub green (review: near-black read as ink)

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
        // Crop rows (3–6 m) or broad mowing stripes on pasture, parallel to one parcel side; faded out
        // before they are thinner than ~2.5 pixels so they never alias.
        let idx = Int(h % UInt32(crops.count))
        let pasture = !autumn && (idx == 0 || idx == 5)
        let spacing: Float = pasture ? 14 : 3 + 3 * Self.unit(h >> 8)
        let coord = (h >> 24) & 1 == 0 ? u : v
        let rowFade = min(1, max(0, 1 - max(0.05, footprint) * 2.5 / spacing))
        col *= 1 + (pasture ? 0.03 : 0.07) * sin(coord / spacing * 6.2831853) * rowFade
        // Distance to the parcel border in metres; crisp hedgerow strip, anti-aliased by footprint.
        let edge = min(tu * Self.parcelU, (1 - tu) * Self.parcelU, tv * Self.parcelV, (1 - tv) * Self.parcelV)
        let fp = max(0.05, footprint)
        let hw = min(Self.hedgeHalfWidth, max(0.3, 1.5 * fp))           // at most ~3 px wide near the camera
        let cover = 1 - min(1, max(0, (edge - hw) / fp + 0.5))     // pixel coverage of the strip
        let strength = min(1, 2 * hw / fp)                           // thinner than a pixel → area-average
        // Hedges break up: gaps where the noise is low, so lines are not ruled.
        let gaps = Self.noise(u / 18, v / 18, seed ^ 0x77) > -0.55 ? Float(1) : 0
        let hedgeAmount = cover * strength * gaps
        return col + (Self.hedge - col) * hedgeAmount
    }

    // MARK: Built-up impostor

    /// Roofs of distant houses (linear albedo): dark grey, red-brown, slate, terracotta, light grey.
    static let roofs: [SIMD3<Float>] = [SIMD3(0.050, 0.050, 0.055), SIMD3(0.170, 0.060, 0.040), SIMD3(0.080, 0.090, 0.100),
                                        SIMD3(0.250, 0.090, 0.050), SIMD3(0.200, 0.200, 0.190)]
    static let street = SIMD3<Float>(0.060, 0.060, 0.065)

    /// Suburb beyond the object radius as seen from far away: 90 × 140 m blocks bounded by 8 m streets,
    /// two rows of 18 m lots, a 10 × 12 m house per lot with a hashed roof, and some lots with a tree.
    /// Returns the albedo replacing `lawn`; detail averages out as the pixel footprint grows.
    public func town(_ x: Float, _ y: Float, footprint: Float, lawn: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(Self.angle + 0.2), s = sin(Self.angle + 0.2)
        let u = c * x + s * y, v = -s * x + c * y
        let bu = (u / 90).rounded(.down), bv = (v / 140).rounded(.down)
        let lu = u - bu * 90, lv = v - bv * 140                       // metres within the block
        let roadEdge = min(min(lu, 90 - lu), min(lv, 140 - lv))
        // Area average: streets 14 %, roofs 7.5 %, lawn the rest less tree and shadow darkening.
        let mean = Self.street * 0.14 + SIMD3<Float>(0.150, 0.098, 0.087) * 0.075 + lawn * 0.765
        let fp = max(0.05, footprint)
        let detailW = 1 - min(1, max(0, (fp - 3) / 12))
        if detailW <= 0 { return mean }
        var col: SIMD3<Float>
        if roadEdge < 4 {
            col = Self.street
        } else {
            // Lots: two rows (split at lv = 70), 18 m wide along u.
            let row: Float = lv < 70 ? 0 : 1
            let lotI = ((lu - 4) / 18).rounded(.down)
            let h = Self.hash(Int32(bu) &* 8 &+ Int32(lotI), Int32(bv) &* 2 &+ Int32(row), seed ^ 0x70E1)
            let lx = lu - 4 - lotI * 18 - 9                            // −9…9 across the lot
            let ly = (row == 0 ? lv - 4 : 136 - lv) - 22               // house set back from the street
            let jx = (Self.unit(h) - 0.5) * 3, jy = (Self.unit(h >> 8) - 0.5) * 4
            let inHouse = abs(lx - jx) < 5 && abs(ly - jy) < 6 && Self.unit(h >> 16) < 0.86
            if inHouse {
                col = Self.roofs[Int(h % UInt32(Self.roofs.count))]
            } else {
                col = lawn
                // Shadowed side of the house and a tree in some back gardens.
                if abs(lx - jx) < 5 && ly - jy > 6 && ly - jy < 9 && Self.unit(h >> 16) < 0.86 { col *= 0.55 }
                let tx = lx - (Self.unit(h >> 4) - 0.5) * 10, ty = ly - 18
                if Self.unit(h >> 12) < 0.45 && tx * tx + ty * ty < 16 { col = lawn * SIMD3(0.45, 0.55, 0.45) }
            }
        }
        return mean + (col - mean) * detailW
    }
}
