// SKYFORGE — Apache-2.0
// Simulation-facing weather derived from a METAR or from an offline procedural preset.
import Foundation
import SFMath
import SFAtmosphere

public struct WeatherState: Sendable, Equatable {
    /// Wind the air moves *toward*, NED frame (m/s), at the surface.
    public var surfaceWindNED: SIMD3<Double>
    public var gustMps: Double
    public var qnhPa: Double
    /// Temperature deviation from ISA at the station (K).
    public var isaDeviation: Double
    public var visibilityMetres: Double
    public var cloudLayers: [(cover: Double, baseMetres: Double, convective: Bool)]
    public var precipitation: Bool
    public var source: String

    public static func == (a: WeatherState, b: WeatherState) -> Bool {
        a.surfaceWindNED == b.surfaceWindNED && a.gustMps == b.gustMps && a.qnhPa == b.qnhPa &&
            a.isaDeviation == b.isaDeviation && a.visibilityMetres == b.visibilityMetres &&
            a.cloudLayers.count == b.cloudLayers.count && a.precipitation == b.precipitation && a.source == b.source
    }

    /// Converts a METAR (meteorological "wind from" direction) into simulation weather.
    public init(metar m: METAR, stationElevationMetres: Double) {
        let speed = (m.wind?.speedKnots ?? 0) * Units.knotsToMps
        let fromDeg = Double(m.wind?.directionDegrees ?? 0)
        let toward = (fromDeg + 180) * Units.degToRad
        surfaceWindNED = SIMD3(speed * cos(toward), speed * sin(toward), 0)
        gustMps = max(0, ((m.wind?.gustKnots ?? m.wind?.speedKnots ?? 0) - (m.wind?.speedKnots ?? 0))) * Units.knotsToMps
        qnhPa = (m.qnhHectopascals ?? 1013.25) * 100
        let isaT = ISA.state(geometricAltitude: stationElevationMetres).temperature - 273.15
        isaDeviation = (m.temperatureC ?? isaT) - isaT
        visibilityMetres = m.visibilityMetres ?? 10_000
        cloudLayers = m.clouds.map { ($0.cover.fraction, Double($0.baseFeet ?? 3_000) * Units.feetToMetres + stationElevationMetres, $0.convective != nil) }
        if let vv = m.verticalVisibilityFeet { cloudLayers.append((1, Double(vv) * Units.feetToMetres + stationElevationMetres, false)) }
        precipitation = m.weather.contains { $0.contains("RA") || $0.contains("SN") || $0.contains("DZ") || $0.contains("GR") }
        source = "METAR \(m.station) \(String(format: "%02d%02d%02dZ", m.day, m.hour, m.minute))"
    }

    public init(surfaceWindNED: SIMD3<Double>, gustMps: Double, qnhPa: Double, isaDeviation: Double, visibilityMetres: Double,
                cloudLayers: [(cover: Double, baseMetres: Double, convective: Bool)], precipitation: Bool, source: String) {
        self.surfaceWindNED = surfaceWindNED; self.gustMps = gustMps; self.qnhPa = qnhPa; self.isaDeviation = isaDeviation
        self.visibilityMetres = visibilityMetres; self.cloudLayers = cloudLayers; self.precipitation = precipitation; self.source = source
    }

    /// Wind at a height above ground using a 1/7 power law (neutral boundary layer), capped at 600 m.
    public func wind(heightAGL h: Double) -> SIMD3<Double> {
        let factor = pow(max(1, min(h, 600)) / 10, 1.0 / 7.0)
        return surfaceWindNED * factor
    }
}

/// Offline procedural weather presets (used automatically when no network is available).
public enum WeatherPreset: String, Sendable, CaseIterable {
    case clear, scattered, overcast, storm, gustyCrosswind

    public func state(seed: UInt64) -> WeatherState {
        var rng = Xoshiro256(seed: Hash.combine(seed, UInt64(rawValue.hashValue & 0xFFFF)))
        func windFrom(_ deg: Double, _ kt: Double) -> SIMD3<Double> {
            let to = (deg + 180) * Units.degToRad
            return SIMD3(cos(to), sin(to), 0) * kt * Units.knotsToMps
        }
        let dir = (rng.unit() * 36).rounded(.down) * 10
        switch self {
        case .clear:
            return WeatherState(surfaceWindNED: windFrom(dir, 4 + rng.unit() * 4), gustMps: 0, qnhPa: 102_000, isaDeviation: 0,
                                visibilityMetres: 40_000, cloudLayers: [], precipitation: false, source: "preset clear")
        case .scattered:
            return WeatherState(surfaceWindNED: windFrom(dir, 8 + rng.unit() * 5), gustMps: 0, qnhPa: 101_600, isaDeviation: 2,
                                visibilityMetres: 25_000, cloudLayers: [(3.5 / 8, 1_200, false), (2.0 / 8, 2_800, false)],
                                precipitation: false, source: "preset scattered")
        case .overcast:
            return WeatherState(surfaceWindNED: windFrom(dir, 10 + rng.unit() * 6), gustMps: 2, qnhPa: 100_800, isaDeviation: -3,
                                visibilityMetres: 8_000, cloudLayers: [(1, 600, false)], precipitation: rng.unit() < 0.5, source: "preset overcast")
        case .storm:
            return WeatherState(surfaceWindNED: windFrom(dir, 18 + rng.unit() * 8), gustMps: 9, qnhPa: 99_500, isaDeviation: -5,
                                visibilityMetres: 3_000, cloudLayers: [(6.0 / 8, 450, true), (1, 2_000, false)], precipitation: true, source: "preset storm")
        case .gustyCrosswind:
            return WeatherState(surfaceWindNED: windFrom(dir, 15 + rng.unit() * 5), gustMps: 6, qnhPa: 101_000, isaDeviation: 0,
                                visibilityMetres: 20_000, cloudLayers: [(2.0 / 8, 1_500, false)], precipitation: false, source: "preset gusty crosswind")
        }
    }
}
