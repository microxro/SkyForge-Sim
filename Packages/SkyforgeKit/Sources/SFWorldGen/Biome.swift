// SKYFORGE — Apache-2.0
// Climate/biome classification and the art-directed palette (linear-light RGB).
import Foundation
import SFMath

public enum Biome: String, Sendable, CaseIterable, Codable {
    case ice, tundra, boreal, temperateForest, grassland, savanna, desert, rainforest, wetland, cropland, urban, beach, rock, snow
}

public enum Season: String, Sendable, CaseIterable, Codable {
    case spring, summer, autumn, winter
}

/// Linear-light colour.
public typealias LinearRGB = SIMD3<Float>

@inlinable public func srgb(_ r: Int, _ g: Int, _ b: Int) -> LinearRGB {
    func c(_ v: Int) -> Float {
        let s = Float(v) / 255
        return s <= 0.04045 ? s / 12.92 : powf((s + 0.055) / 1.055, 2.4)
    }
    return LinearRGB(c(r), c(g), c(b))
}

public struct ClimateInputs: Sendable {
    public var latitude: Double          // degrees
    public var elevation: Double         // m
    public var slope: Double             // rad
    public var moisture: Double          // 0…1 (noise + distance to water)
    public var distanceToWater: Double   // m
    public init(latitude: Double, elevation: Double, slope: Double, moisture: Double, distanceToWater: Double) {
        self.latitude = latitude; self.elevation = elevation; self.slope = slope
        self.moisture = moisture; self.distanceToWater = distanceToWater
    }
}

public enum BiomeClassifier {
    /// Mean annual temperature estimate (°C): latitude band plus a 6.5 K/km lapse rate.
    public static func temperature(latitude: Double, elevation: Double) -> Double {
        let lat = abs(latitude)
        return 28 - 0.45 * max(0, lat - 12) - 0.0065 * max(0, elevation)
    }

    public static func classify(_ c: ClimateInputs) -> Biome {
        let t = temperature(latitude: c.latitude, elevation: c.elevation)
        if c.distanceToWater < 25 && c.elevation < 8 { return .beach }
        if t < -8 { return .ice }
        if c.slope > 0.85 { return t < 0 ? .snow : .rock }
        if t < -2 { return c.slope > 0.5 ? .rock : .snow }
        if t < 2 { return .tundra }
        if t < 6 { return c.moisture > 0.35 ? .boreal : .tundra }
        if t < 20 {
            if c.moisture < 0.2 { return .grassland }
            if c.moisture > 0.85 && c.slope < 0.05 { return .wetland }
            return .temperateForest
        }
        if c.moisture < 0.2 { return .desert }
        if c.moisture < 0.5 { return .savanna }
        return .rainforest
    }
}

/// Art-directed ground colours per biome and season (restrained saturation, §8.0).
public enum GroundPalette {
    public static func colour(_ b: Biome, season: Season) -> LinearRGB {
        switch b {
        case .ice: return srgb(232, 238, 245)
        case .snow: return srgb(236, 240, 246)
        case .tundra: return season == .winter ? srgb(220, 224, 230) : srgb(128, 122, 92)
        case .boreal: return season == .winter ? srgb(196, 204, 210) : srgb(58, 74, 48)
        case .temperateForest:
            switch season {
            case .autumn: return srgb(86, 90, 56)
            case .winter: return srgb(112, 108, 96)
            default: return srgb(72, 96, 50)
            }
        case .grassland:
            switch season {
            case .autumn: return srgb(122, 120, 74)
            case .summer: return srgb(124, 132, 70)
            case .winter: return srgb(132, 128, 104)
            case .spring: return srgb(96, 128, 62)
            }
        case .savanna: return srgb(176, 150, 92)
        case .desert: return srgb(210, 180, 132)
        case .rainforest: return srgb(48, 82, 40)
        case .wetland: return srgb(86, 98, 64)
        case .cropland: return srgb(140, 132, 76)
        case .urban: return srgb(128, 124, 116)
        case .beach: return srgb(214, 198, 160)
        case .rock: return srgb(120, 112, 104)
        }
    }
}
