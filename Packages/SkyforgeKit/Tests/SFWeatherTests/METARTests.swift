import Testing
import Foundation
import SFMath
@testable import SFWeather

@Suite struct METARTests {
    static var fixtures: [String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/metar/metars.txt")
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func atLeast200RealFixturesParse() throws {
        let all = Self.fixtures
        #expect(all.count >= 200)
        var withPressure = 0, withWind = 0
        for line in all {
            let m = try METARParser.parse(line)
            #expect(m.station.count == 4)
            if let q = m.qnhHectopascals {
                withPressure += 1
                #expect(q > 900 && q < 1_090, "\(line)")
            }
            if let w = m.wind {
                withWind += 1
                #expect(w.speedKnots >= 0 && w.speedKnots < 150, "\(line)")
                if let g = w.gustKnots { #expect(g >= w.speedKnots, "\(line)") }
                if let d = w.directionDegrees { #expect((0...360).contains(d)) }
            }
            if let t = m.temperatureC { #expect(t > -70 && t < 60, "\(line)") }
            if let t = m.temperatureC, let d = m.dewpointC { #expect(d <= t + 0.5, "\(line)") }
            if let v = m.visibilityMetres { #expect(v >= 0 && v <= 200_000, "\(line)") }   // Canada/Alaska report up to 60SM+
            for c in m.clouds { if let b = c.baseFeet { #expect(b >= 0 && b <= 50_000) } }
        }
        #expect(withPressure > all.count * 8 / 10)
        #expect(withWind > all.count * 8 / 10)
    }

    @Test func fullUSReport() throws {
        let m = try METARParser.parse("METAR KSFO 072156Z 20004KT 10SM BKN200 22/13 A3007 RMK AO2 WSHFT 2118 SLP182 T02170128")
        #expect(m.station == "KSFO" && m.day == 7 && m.hour == 21 && m.minute == 56)
        #expect(m.wind == Wind(directionDegrees: 200, speedKnots: 4, gustKnots: nil))
        #expect(abs((m.visibilityMetres ?? 0) - 16_093.44) < 0.01)
        #expect(m.clouds == [CloudLayer(cover: .broken, baseFeet: 20_000, convective: nil)])
        #expect(m.temperatureC == 22 && m.dewpointC == 13)
        #expect(abs((m.qnhHectopascals ?? 0) - 1018.3) < 0.05)
        #expect(m.altimeterWasInHg)
        #expect(m.flightCategory == "VFR")
    }

    @Test func europeanWithTrendAndFog() throws {
        let m = try METARParser.parse("METAR LFPG 072230Z 19004KT 3500 BR FEW002 BKN003 06/06 Q1023 TEMPO 0600 FG")
        #expect(m.visibilityMetres == 3500)
        #expect(m.weather == ["BR"])   // TEMPO group is not part of the current observation
        #expect(m.ceilingFeet == 300)
        #expect(m.qnhHectopascals == 1023)
        #expect(m.flightCategory == "LIFR")
    }

    @Test func cavokGustsVariableAndNegativeTemps() throws {
        let m = try METARParser.parse("EDDM 071950Z 24015G28KT 210V280 CAVOK M02/M08 Q1031 NOSIG")
        #expect(m.cavok && m.visibilityMetres == 10_000)
        #expect(m.wind?.gustKnots == 28 && m.wind?.variableFrom == 210 && m.wind?.variableTo == 280)
        #expect(m.temperatureC == -2 && m.dewpointC == -8)
    }

    @Test func fractionalMilesRVRVerticalVisibility() throws {
        let m = try METARParser.parse("SPECI KBOS 071854Z 05012KT 1 1/2SM R04R/2400V3000FT -SN BR VV008 M01/M02 A2992")
        #expect(m.isSpeci)
        #expect(abs((m.visibilityMetres ?? 0) - 1.5 * 1_609.344) < 0.01)
        #expect(m.rvr.first?.runway == "04R" && m.rvr.first?.metres == 731)
        #expect(m.weather == ["-SN", "BR"])
        #expect(m.verticalVisibilityFeet == 800 && m.ceilingFeet == 800)
        #expect(m.flightCategory == "IFR")
        let q = try METARParser.parse("KXYZ 071854Z 00000KT M1/4SM FG VV001 10/10 A3001")
        #expect(abs((q.visibilityMetres ?? 0) - 402.336) < 0.01)
        #expect(q.wind?.isCalm == true)
    }

    @Test func metresPerSecondVrbAndMissingFields() throws {
        let m = try METARParser.parse("METAR UUEE 072200Z VRB02MPS 9999 // ///////// /////CB 03/// Q1020")
        #expect(m.wind?.directionDegrees == nil)
        #expect(abs((m.wind?.speedKnots ?? 0) - 3.887688) < 1e-5)
        #expect(m.temperatureC == 3 && m.dewpointC == nil)
        let nilReport = try METARParser.parse("METAR ZZZZ 072200Z NIL")
        #expect(nilReport.isNil && nilReport.wind == nil)
    }

    @Test func thunderstormWithCB() throws {
        let m = try METARParser.parse("KMIA 071753Z 27018G32KT 3SM +TSRA BKN015CB OVC040 24/22 A2990")
        #expect(m.weather == ["+TSRA"])
        #expect(m.clouds.first?.convective == "CB")
        #expect(m.flightCategory == "MVFR")
    }

    @Test func rejectsGarbageGracefully() {
        #expect(throws: METARError.self) { try METARParser.parse("") }
        #expect(throws: METARError.self) { try METARParser.parse("HELLO WORLD") }
        #expect(throws: METARError.self) { try METARParser.parse("KSFO 99XXXXZ 20004KT") }
    }

    @Test func fuzzNeverCrashes() {
        var rng = Xoshiro256(seed: 77)
        let corpus = Self.fixtures
        let alphabet = Array("0123456789/ABCDEFGKLMNOPQRSTUVWXYZ+- ")
        for k in 0..<5_000 {
            var chars = Array(corpus[k % corpus.count])
            let edits = Int(rng.next() % 8)
            for _ in 0..<edits where !chars.isEmpty {
                let p = Int(rng.next() % UInt64(chars.count))
                switch rng.next() % 3 {
                case 0: chars[p] = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                case 1: chars.remove(at: p)
                default: chars.insert(alphabet[Int(rng.next() % UInt64(alphabet.count))], at: p)
                }
            }
            _ = try? METARParser.parse(String(chars))
        }
    }
}
