// SKYFORGE — Apache-2.0
// Season, daylength and ground snow from the date, latitude and the weather at the surface. Pure functions over
// plain values, so the renderer can read `SeasonalConditions` for snow cover and canopy colour, and the sim can
// use the same numbers for daylength without depending on any renderer code.
import Foundation

public enum WeatherSeason: String, Sendable, CaseIterable {
    case spring, summer, autumn, winter
}

public struct SeasonalConditions: Sendable, Equatable {
    /// Season for the hemisphere of the observer (northern and southern seasons are opposite).
    public var season: WeatherSeason
    /// Solar declination (degrees). Positive in the northern summer.
    public var solarDeclinationDeg: Double
    /// Hours of daylight at the observer's latitude on this day (0 at polar night, 24 at polar day).
    public var dayLengthHours: Double
    /// Fraction (0...1) of the ground covered by snow.
    public var snowCover: Double
    /// Autumn colour strength for deciduous canopy (0 = green, 1 = peak colour).
    public var autumnColour: Double
    /// Fraction (0...1) of deciduous leaves that have fallen.
    public var leafFall: Double

    /// Obliquity of the ecliptic used for the solar declination.
    static let obliquityDeg = 23.44

    /// Evaluates the conditions for a day of year (1...366, fractional values allowed).
    /// - Parameters:
    ///   - dayOfYear: day of year, 1 on January 1st.
    ///   - latitudeDeg: observer latitude, positive north.
    ///   - surfaceTemperatureC: current air temperature near the ground, if known (live METAR or model data).
    ///   - snowfallRecent: true when snow is reported now or in the last few hours.
    public static func evaluate(dayOfYear: Double, latitudeDeg: Double, surfaceTemperatureC: Double?,
                                snowfallRecent: Bool) -> SeasonalConditions {
        let lat = max(-90, min(90, latitudeDeg))
        let declination = declinationDeg(dayOfYear)

        // Seasons follow the calendar at the equinoxes and solstices, with the southern hemisphere half a year out
        // of phase. Declination alone would put late October in winter, because the sun is low for weeks before
        // the cold arrives.
        var n = dayOfYear.truncatingRemainder(dividingBy: 365)
        if n < 1 { n += 365 }
        if lat < 0 {
            n = (n + 182.5).truncatingRemainder(dividingBy: 365)
            if n < 1 { n += 365 }
        }
        let season: WeatherSeason
        if n < 80 || n >= 355 { season = .winter }
        else if n < 172 { season = .spring }
        else if n < 266 { season = .summer }
        else { season = .autumn }

        let dayLength = dayLengthHours(latitudeDeg: lat, declinationDeg: declination)

        // Snow climatology: none south of about 30°, full climate potential from about 40° poleward.
        let snowLatitude = clamp01((abs(lat) - 30) / 10)
        var snow: Double
        if let t = surfaceTemperatureC {
            // Full cover at -4 °C and below, none at 2 °C and above.
            let cold = clamp01((2 - t) / 6)
            snow = snowLatitude * cold
        } else {
            switch season {
            case .winter: snow = 0.7 * snowLatitude
            case .spring, .autumn: snow = 0.1 * snowLatitude
            case .summer: snow = 0
            }
        }
        if snowfallRecent { snow = max(snow, 0.6 * snowLatitude) }
        // Warm air melts a pack in every season.
        if let t = surfaceTemperatureC, t > 2 { snow = 0 }

        // Autumn colour ramps up from the equinox to a peak about 25 days later. Leaves fall from about day 288.
        let colour = season == .autumn ? clamp01((n - 266) / 25) : 0
        let leaves: Double
        switch season {
        case .winter: leaves = 1
        case .autumn: leaves = clamp01((n - 288) / 35)
        case .spring, .summer: leaves = 0
        }

        return SeasonalConditions(season: season, solarDeclinationDeg: declination, dayLengthHours: dayLength,
                                  snowCover: clamp01(snow), autumnColour: colour, leafFall: leaves)
    }

    /// Convenience for a real date. Day of year is taken in UTC so results do not depend on the device time zone.
    public static func evaluate(date: Date, latitudeDeg: Double, surfaceTemperatureC: Double?,
                                snowfallRecent: Bool) -> SeasonalConditions {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        return evaluate(dayOfYear: Double(day), latitudeDeg: latitudeDeg, surfaceTemperatureC: surfaceTemperatureC,
                        snowfallRecent: snowfallRecent)
    }

    /// Solar declination from the standard cosine approximation (accurate to a fraction of a degree).
    public static func declinationDeg(_ dayOfYear: Double) -> Double {
        -obliquityDeg * cos(2 * Double.pi / 365 * (dayOfYear + 10))
    }

    /// Daylight duration from the sunrise equation, clamped for polar day and polar night.
    public static func dayLengthHours(latitudeDeg: Double, declinationDeg: Double) -> Double {
        let phi = latitudeDeg * Double.pi / 180
        let delta = declinationDeg * Double.pi / 180
        let x = -tan(phi) * tan(delta)
        if x <= -1 { return 24 }
        if x >= 1 { return 0 }
        let halfDayRad = acos(x)
        return 2 * halfDayRad * 12 / Double.pi
    }

    private static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
}
