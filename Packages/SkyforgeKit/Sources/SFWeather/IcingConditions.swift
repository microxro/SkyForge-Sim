// SKYFORGE — Apache-2.0
// Icing exposure from the simulated weather: supercooled liquid water in cloud and the air temperature at
// the aircraft. Pure functions over plain values, so the sim can feed them from a `WeatherState` without
// this module depending on the flight model.
import Foundation
import SFAtmosphere

public enum IcingConditions {
    /// Estimated liquid water content (g/m^3) and static temperature (K) at an altitude.
    public struct Exposure: Sendable, Equatable {
        public var temperatureK: Double
        public var liquidWater: Double
    }

    /// - Parameters:
    ///   - altitude: geometric altitude above mean sea level (m).
    ///   - isaDeviation: station temperature deviation from ISA (K), as in `WeatherState`.
    ///   - cloudLayers: cloud layers as in `WeatherState`.
    ///   - visibilityMetres: prevailing visibility.
    ///   - precipitation: whether precipitation is reported.
    public static func exposure(altitude: Double, isaDeviation: Double,
                                cloudLayers: [(cover: Double, baseMetres: Double, convective: Bool)],
                                visibilityMetres: Double, precipitation: Bool) -> Exposure {
        let temperature = ISA.state(geometricAltitude: altitude, temperatureOffset: isaDeviation).temperature
        var lwc = 0.0
        for layer in cloudLayers where layer.cover >= 0.5 {
            // Stratiform cloud is about 1,500 m thick, convective cloud about 3,000 m.
            let thickness = layer.convective ? 3_000.0 : 1_500.0
            guard altitude >= layer.baseMetres && altitude <= layer.baseMetres + thickness else { continue }
            let peak = layer.convective ? 0.5 : 0.25     // g/m^3 at full cover
            lwc = max(lwc, peak * layer.cover)
        }
        // Precipitation in reduced visibility (fog, drizzle) also carries supercooled water.
        if precipitation && visibilityMetres < 5_000 { lwc = max(lwc, 0.1) }
        return Exposure(temperatureK: temperature, liquidWater: lwc)
    }
}
