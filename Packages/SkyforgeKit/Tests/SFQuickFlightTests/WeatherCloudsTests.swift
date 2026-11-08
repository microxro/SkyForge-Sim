// SKYFORGE — Apache-2.0
import Testing
import SFWeather
import SFAtmosphere
import SFContent
import Foundation
@testable import SFQuickFlight

@Suite struct WeatherCloudsTests {
    func layer(_ s: String, elev: Double = 3) throws -> SFAtmosphere.CloudLayer {
        WeatherClouds.layer(from: try METARParser.parse(s), fieldElevation: elev)
    }

    @Test func clearReportsGiveNoClouds() throws {
        #expect(try layer("KMLB 081253Z 34008KT 10SM CLR 22/14 A3005").coverage == 0)
        #expect(try layer("EGLL 081250Z 27010KT CAVOK 12/06 Q1021").coverage == 0)
    }

    @Test func scatteredCumulusAtReportedBase() throws {
        let l = try layer("KTIX 081256Z 09012KT 10SM FEW025 SCT045 28/21 A3002", elev: 10)
        #expect(abs(l.coverage - 0.42) < 1e-6)
        #expect(abs(l.base - Float(10 + 4_500 * 0.3048)) < 1)
    }

    @Test func overcastIsDenseAndFlatAndCBIsDeep() throws {
        let ovc = try layer("KMLB 081253Z 02010KT 5SM BR OVC008 20/19 A2998")
        #expect(ovc.coverage > 0.9 && ovc.thickness < 1_000 && ovc.extinction > 0.05)
        let cb = try layer("KMLB 081953Z 24015G25KT 3SM TSRA BKN030CB 26/23 A2990")
        #expect(cb.thickness > 3_000 && abs(cb.coverage - 0.66) < 1e-6)
    }

    actor ScriptedMETAR: HTTPTransport {
        func get(_ url: URL) async throws -> Data {
            if url.absoluteString.contains("KTIX") { return Data("KTIX 081256Z 09012KT 10SM SCT045 28/21 A3002\n".utf8) }
            throw TransportError.offline
        }
    }

    @Test func liveFallsBackToTheNextStation() async throws {
        let svc = METARService(transport: ScriptedMETAR())
        let r = try #require(await WeatherClouds.live(stations: ["KCOI", "KTIX"], fieldElevation: 3, service: svc))
        #expect(r.raw.hasPrefix("KTIX") && abs(r.layer.coverage - 0.42) < 1e-6)
        #expect(await WeatherClouds.live(stations: ["KCOI"], fieldElevation: 3, service: svc) == nil)
    }
}
