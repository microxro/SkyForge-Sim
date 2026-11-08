// SKYFORGE — Apache-2.0
// Maps a live METAR's sky condition to the volumetric cloud layer (SFAtmosphere.CloudLayer).
import Foundation
import SFAtmosphere
import SFWeather

public enum WeatherClouds {
    /// Cloud layer for a report at a field `fieldElevation` metres AMSL. Uses the most extensive
    /// reported layer (lowest on ties); CLR/SKC/CAVOK/NSC give a clear sky.
    public static func layer(from m: METAR, fieldElevation: Double) -> SFAtmosphere.CloudLayer {
        if m.cavok || m.skyClear || m.clouds.isEmpty {
            if let vv = m.verticalVisibilityFeet {   // obscured sky: a low, thick, dense layer
                return SFAtmosphere.CloudLayer(base: Float(fieldElevation + Double(vv) * 0.3048), thickness: 700, coverage: 0.95, extinction: 0.08)
            }
            return .clear
        }
        let chosen = m.clouds.enumerated().max { a, b in
            a.element.cover.fraction != b.element.cover.fraction ? a.element.cover.fraction < b.element.cover.fraction : a.offset > b.offset
        }!.element
        let baseFt = Double(chosen.baseFeet ?? 3_000)
        let coverage: Float
        switch chosen.cover {
        case .few: coverage = 0.24
        case .scattered: coverage = 0.42
        case .broken: coverage = 0.66
        case .overcast: coverage = 0.92
        }
        let convective = chosen.convective != nil
        // Cumulus deepen with convection; overcast decks are flatter and denser.
        let thickness: Float = convective ? 3_200 : (chosen.cover == .overcast ? 700 : 1_300)
        let extinction: Float = chosen.cover == .overcast ? 0.07 : 0.045
        return SFAtmosphere.CloudLayer(base: Float(fieldElevation + baseFt * 0.3048), thickness: thickness, coverage: coverage, extinction: extinction)
    }

    /// Fetches the first available report among `stations` (nearest first) and maps its sky condition.
    /// Returns nil when no station answers; callers keep their default sky.
    public static func live(stations: [String], fieldElevation: Double, service: METARService) async -> (layer: SFAtmosphere.CloudLayer, raw: String)? {
        for st in stations {
            if let r = try? await service.report(for: st), !r.metar.isNil {
                return (layer(from: r.metar, fieldElevation: fieldElevation), r.metar.raw)
            }
        }
        return nil
    }
}
