// SKYFORGE — Apache-2.0
// Continent, coastline, mountain and climate fields for the original world. Pure functions of world metres.
import Foundation
import SFMath

struct BaseField: Sendable {
    let continent: GradientNoise2D
    let warp: GradientNoise2D
    let ridges: GradientNoise2D
    let rolling: GradientNoise2D
    let micro: GradientNoise2D
    let climate: GradientNoise2D
    let moisture: GradientNoise2D

    init(seed: UInt64) {
        continent = GradientNoise2D(seed: Hash.combine(seed, 0xC0A1))
        warp = GradientNoise2D(seed: Hash.combine(seed, 0x7A2F))
        ridges = GradientNoise2D(seed: Hash.combine(seed, 0x21D6))
        rolling = GradientNoise2D(seed: Hash.combine(seed, 0x0110))
        micro = GradientNoise2D(seed: Hash.combine(seed, 0x91C0))
        climate = GradientNoise2D(seed: Hash.combine(seed, 0xC117))
        moisture = GradientNoise2D(seed: Hash.combine(seed, 0x4057))
    }

    /// Land-ness: about -0.5 deep ocean to +0.5 inland; the coast is where it crosses zero.
    func continentValue(_ x: Double, _ y: Double) -> (c: Double, wx: Double, wy: Double) {
        let wx = x + 3_500 * warp.fbm(x / 7_000, y / 7_000, octaves: 3)
        let wy = y + 3_500 * warp.fbm(x / 7_000 + 19.7, y / 7_000 - 4.1, octaves: 3)
        return (continent.fbm(wx / 28_000, wy / 28_000, octaves: 5), wx, wy)
    }

    /// Elevation in metres before erosion. Sea floor below 0, plains and ranges above.
    func height(_ x: Double, _ y: Double) -> Double {
        let (c, wx, wy) = continentValue(x, y)
        let coast = smoothstep(-0.04, 0.08, c)
        let plains = 30 + 70 * rolling.fbm(wx / 2_400, wy / 2_400, octaves: 4) + 25
        let ridge = ridges.ridged(wx / 5_500, wy / 5_500, octaves: 5)
        let ranges = 1_250 * pow(ridge, 2.2) * smoothstep(0.12, 0.35, c)
        let seaFloor = -25 - 140 * smoothstep(-0.04, -0.35, c)
        let fine = 3 * micro.fbm(x / 120, y / 120, octaves: 3)
        return lerp(seaFloor, plains + ranges, coast) + fine * coast
    }

    /// Roughly [-0.7, 0.7]: regional warmth, about 20 km scale.
    func climateNoise(_ x: Double, _ y: Double) -> Double {
        climate.fbm(x / 20_000, y / 20_000, octaves: 3)
    }

    /// Roughly [-0.7, 0.7]: regional wetness, about 9 km scale.
    func moistureNoise(_ x: Double, _ y: Double) -> Double {
        moisture.fbm(x / 9_000, y / 9_000, octaves: 3)
    }
}
