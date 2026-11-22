// SKYFORGE — Apache-2.0
// Presentation-facing weather: turns a METAR (or a WeatherState / preset) into the numbers the
// renderer (rain, snow, fog, wind streaks) and the audio engine (rain, wind, thunder) consume.
// Pure Swift, no platform imports, so it is unit-tested on Linux.
import Foundation
import SFMath

public enum PrecipitationKind: String, Sendable, Equatable, CaseIterable {
    case none, drizzle, rain, snow, hail
}

public struct WeatherEffects: Sendable, Equatable {
    public var precipitation: PrecipitationKind
    /// 0 (none) … 1 (torrential / blizzard).
    public var precipitationIntensity: Double
    /// Meteorological visibility (m), after precipitation/obscuration reduction.
    public var visibilityMetres: Double
    /// Fog/haze extinction coefficient (1/m) from the Koschmieder relation (contrast 2 %: 3.912 / V).
    public var fogExtinction: Double
    /// True for mist/fog/low-visibility obscuration (BR, FG, FZFG).
    public var groundFog: Bool
    /// Thunderstorm in the report: drives lightning flashes and thunder.
    public var thunderstorm: Bool
    /// Surface wind speed (m/s) and gust increment (m/s).
    public var windSpeed: Double
    public var gust: Double
    /// Turbulence strength 0…1 (camera shake / audio buffeting), from gusts, wind and convection.
    public var turbulence: Double

    public static let clear = WeatherEffects(precipitation: .none, precipitationIntensity: 0, visibilityMetres: 40_000,
                                             fogExtinction: 3.912 / 40_000, groundFog: false, thunderstorm: false,
                                             windSpeed: 0, gust: 0, turbulence: 0)

    public init(precipitation: PrecipitationKind, precipitationIntensity: Double, visibilityMetres: Double, fogExtinction: Double,
                groundFog: Bool, thunderstorm: Bool, windSpeed: Double, gust: Double, turbulence: Double) {
        self.precipitation = precipitation; self.precipitationIntensity = precipitationIntensity
        self.visibilityMetres = visibilityMetres; self.fogExtinction = fogExtinction; self.groundFog = groundFog
        self.thunderstorm = thunderstorm; self.windSpeed = windSpeed; self.gust = gust; self.turbulence = turbulence
    }

    /// Koschmieder extinction (1/m) for a visibility in metres (clamped to 50 m … 80 km).
    public static func extinction(visibility v: Double) -> Double { 3.912 / min(max(v, 50), 80_000) }

    // MARK: From a METAR

    public init(metar m: METAR) {
        var kind = PrecipitationKind.none
        var intensity = 0.0
        var fog = false
        var ts = false
        for raw in m.weather {
            var t = Substring(raw)
            var level = 0.55                                  // moderate (no prefix)
            if t.hasPrefix("-") { level = 0.25; t = t.dropFirst() }
            else if t.hasPrefix("+") { level = 0.9; t = t.dropFirst() }
            if t.hasPrefix("VC") { continue }                 // in the vicinity: not over the field
            if t.hasPrefix("RE") { t = t.dropFirst(2) }       // recent weather
            if t.hasPrefix("BL") || t.hasPrefix("DR") { continue }   // blowing/drifting snow, sand, dust: not falling precipitation
            if t.contains("TS") { ts = true; level = max(level, 0.7) }
            // Order matters: the most severe form present wins.
            let found: PrecipitationKind
            if t.contains("GR") || t.contains("GS") { found = .hail }
            else if t.contains("SN") || t.contains("SG") || t.contains("PL") { found = .snow }
            else if t.contains("RA") { found = .rain }
            else if t.contains("DZ") { found = .drizzle; level = min(level, 0.3) }
            else { found = .none }
            if found != .none, level >= intensity { kind = found; intensity = level }
            if t.contains("FG") || t.contains("BR") { fog = true }
        }
        let vis = m.visibilityMetres ?? 10_000
        let wind = (m.wind?.speedKnots ?? 0) * Units.knotsToMps
        let gustIncrement = max(0, (m.wind?.gustKnots ?? m.wind?.speedKnots ?? 0) - (m.wind?.speedKnots ?? 0)) * Units.knotsToMps
        let convective = m.clouds.contains { $0.convective != nil }
        self.init(precipitation: kind, precipitationIntensity: intensity, visibilityMetres: vis,
                  fogExtinction: Self.extinction(visibility: vis), groundFog: fog, thunderstorm: ts,
                  windSpeed: wind, gust: gustIncrement,
                  turbulence: Self.turbulence(wind: wind, gust: gustIncrement, convective: convective || ts))
    }

    // MARK: From a WeatherState (METAR-derived or offline preset)

    public init(state s: WeatherState) {
        let wind = hypot(s.surfaceWindNED.x, s.surfaceWindNED.y)
        let convective = s.cloudLayers.contains { $0.convective }
        let kind: PrecipitationKind = s.precipitation ? .rain : .none
        let intensity = s.precipitation ? (convective ? 0.85 : 0.5) : 0
        self.init(precipitation: kind, precipitationIntensity: intensity, visibilityMetres: s.visibilityMetres,
                  fogExtinction: Self.extinction(visibility: s.visibilityMetres), groundFog: s.visibilityMetres < 1_000,
                  thunderstorm: convective && s.precipitation, windSpeed: wind, gust: s.gustMps,
                  turbulence: Self.turbulence(wind: wind, gust: s.gustMps, convective: convective))
    }

    /// Gusts dominate; steady wind adds a floor; convective air adds more.
    static func turbulence(wind: Double, gust: Double, convective: Bool) -> Double {
        let v = 0.05 * wind + 0.09 * gust + (convective ? 0.3 : 0)
        return min(max(v, 0), 1)
    }

    // MARK: Time-varying parts

    /// Wind magnitude (m/s) at `time`: the mean plus gusts as a sum of incommensurate sinusoids,
    /// deterministic so the picture and the sound agree without sharing a random generator.
    public func windSpeed(at time: Double) -> Double {
        guard gust > 0 else { return windSpeed }
        let g = 0.5 + 0.3 * sin(time * 0.7) + 0.15 * sin(time * 1.9 + 1.3) + 0.05 * sin(time * 4.3 + 0.4)
        return windSpeed + gust * max(0, g)
    }

    /// Lightning flash brightness 0…1 at `time` (0 when no thunderstorm). Flashes recur every ~7–19 s
    /// from a fixed hash sequence, each a 2-pulse flicker lasting ~0.35 s.
    public func lightning(at time: Double, seed: UInt64 = 1) -> Double {
        guard thunderstorm, time.isFinite, time >= 0 else { return 0 }
        var t = 0.0
        var i: UInt64 = 0
        while t < time + 20, i < 20_000 {
            let gap = 7 + 12 * Self.unit(seed, i)
            t += gap
            let dt = time - t
            if dt >= 0 && dt < 0.35 {
                let pulse1 = max(0, 1 - dt / 0.12)
                let pulse2 = dt > 0.16 ? max(0, 1 - (dt - 0.16) / 0.19) * 0.7 : 0
                return min(1, max(pulse1, pulse2))
            }
            if t > time { break }
            i += 1
        }
        return 0
    }

    /// Next flash start time at or after `time` (used to schedule the delayed thunder clap).
    public func nextLightning(after time: Double, seed: UInt64 = 1) -> Double? {
        guard thunderstorm, time.isFinite else { return nil }
        let time = max(time, 0)
        var t = 0.0
        var i: UInt64 = 0
        while t <= time + 40, i < 20_000 {
            t += 7 + 12 * Self.unit(seed, i)
            if t >= time { return t }
            i += 1
        }
        return nil
    }

    /// Deterministic uniform [0,1) from a seed and index (shared with the audio model).
    public static func unit(_ seed: UInt64, _ i: UInt64) -> Double {
        var sm = SplitMix64(seed: seed &+ i &* 0x9E37_79B9_7F4A_7C15)
        return Double(sm.next() >> 11) / Double(1 << 53)
    }

    // MARK: Renderer parameters

    /// Streak count, speed and length for the precipitation overlay (all unitless screen-space tuning).
    public struct PrecipitationLook: Sendable, Equatable {
        public var density: Float      // 0…1 share of cells holding a streak
        public var fallSpeed: Float    // m/s (rain ≈ 7–9, snow ≈ 1–1.5, hail ≈ 12)
        public var streakLength: Float // seconds of travel drawn as the streak
        public var wetness: Float      // 0…1 overall dimming/greying of the scene
    }

    public var precipitationLook: PrecipitationLook {
        let i = Float(precipitationIntensity)
        switch precipitation {
        case .none: return PrecipitationLook(density: 0, fallSpeed: 0, streakLength: 0, wetness: 0)
        case .drizzle: return PrecipitationLook(density: 0.15 * i + 0.05, fallSpeed: 3, streakLength: 0.03, wetness: 0.2 * i)
        case .rain: return PrecipitationLook(density: 0.1 + 0.55 * i, fallSpeed: 8, streakLength: 0.05 + 0.03 * i, wetness: 0.45 * i)
        case .snow: return PrecipitationLook(density: 0.08 + 0.4 * i, fallSpeed: 1.2, streakLength: 0.01, wetness: 0.1 * i)
        case .hail: return PrecipitationLook(density: 0.08 + 0.3 * i, fallSpeed: 14, streakLength: 0.025, wetness: 0.4 * i)
        }
    }
}
