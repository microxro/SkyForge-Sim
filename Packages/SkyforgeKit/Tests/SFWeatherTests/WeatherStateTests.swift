import Testing
import SFMath
@testable import SFWeather

@Suite struct WeatherStateTests {
    @Test func windFromWestBlowsEast() throws {
        let m = try METARParser.parse("KXXX 071200Z 27020KT 9999 FEW030 15/05 Q1013")
        let w = WeatherState(metar: m, stationElevationMetres: 0)
        #expect(abs(w.surfaceWindNED.y - 20 * Units.knotsToMps) < 1e-9)   // toward east
        #expect(abs(w.surfaceWindNED.x) < 1e-9)
        #expect(abs(w.qnhPa - 101_300) < 1e-6)
        #expect(abs(w.isaDeviation) < 1e-6)                                  // 15 °C at sea level is ISA
        #expect(w.wind(heightAGL: 300).y > w.surfaceWindNED.y)
    }

    @Test func presetsAreDeterministicAndPlausible() {
        for p in WeatherPreset.allCases {
            let a = p.state(seed: 3), b = p.state(seed: 3)
            #expect(a == b)
            #expect(a.qnhPa > 95_000 && a.qnhPa < 105_000)
            #expect(a.visibilityMetres > 0)
        }
    }
}
