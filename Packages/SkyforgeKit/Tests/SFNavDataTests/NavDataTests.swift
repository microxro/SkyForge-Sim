import Testing
import Foundation
import SFMath
@testable import SFNavData

@Suite struct NavDataTests {
    static func load(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ourairports/\(name).csv")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
    static let db = NavDatabase(airportsCSV: load("airports"), runwaysCSV: load("runways"), navaidsCSV: load("navaids"))

    @Test func csvQuotingAndUnicode() {
        let rows = CSV.parse("a,b,c\n\"x, y\",\"he said \"\"hi\"\"\",\"Aeroestación\nYabotí\"\n1,,3")
        #expect(rows.count == 3)
        #expect(rows[1] == ["x, y", "he said \"hi\"", "Aeroestación\nYabotí"])
        #expect(rows[2] == ["1", "", "3"])
        #expect(Self.db.airport("0GA2")?.name == "Airnautique, Inc. Airport")
        #expect(Self.db.airport("AR-0767")?.name == "Aeroestación Yabotí")
    }

    @Test func ksfoRunways() throws {
        let rws = Self.db.runways(at: "KSFO")
        #expect(rws.count == 4)
        let r = try #require(rws.first { $0.low.ident == "10L" })
        #expect(r.lengthFeet == 11_870 && r.high.ident == "28R")
        // Heading from coordinates agrees with the published true heading (118°) within 1.5°.
        let h = try #require(r.computedHeadingDegrees)
        #expect(abs(h - 118) < 1.5, "computed \(h)")
        // Threshold separation is consistent with the listed length (thresholds may be displaced).
        let sep = try #require(r.thresholdSeparationMetres)
        #expect(abs(sep - r.lengthMetres) < 120, "separation \(sep) vs length \(r.lengthMetres)")
        #expect(r.isHardSurface && r.lighted && !r.closed)
    }

    @Test func runwaysWithoutGeometryAreFlagged() {
        let heli = Self.db.runways(at: "00A")
        #expect(!heli.isEmpty && heli.allSatisfy { !$0.hasGeometry })
    }

    @Test func syntheticILSOnlyOnLongHardRunways() {
        let ils = Self.db.syntheticILS(at: "KSFO")
        #expect(ils.count == 8)
        #expect(ils.allSatisfy { $0.isSynthetic && $0.label.contains("Synthetic") && $0.glideslopeDegrees == 3 })
        let rwy28R = ils.first { $0.runwayIdent == "28R" }
        #expect(rwy28R.map { abs($0.courseTrueDegrees - 298) < 1.5 } == true)
        #expect(Self.db.syntheticILS(at: "00A").isEmpty)
    }

    @Test func navaidLookupAndBearingDistance() throws {
        let sfo = try #require(Self.db.navaids(ident: "SFO").first)
        #expect(sfo.type == .vortac || sfo.type == .vorDme || sfo.type == .vor)
        #expect(abs(sfo.frequencyMHz - 115.8) < 0.01)
        let airport = try #require(Self.db.airport("KSFO"))
        let bd = NavDatabase.bearingDistance(from: airport.position, to: sfo)
        #expect(bd.distanceNM < 1.5)   // the SFO VOR-DME is on the airport
        #expect(bd.bearingTrue >= 0 && bd.bearingTrue < 360)
        // Oakland VOR from San Francisco: across the bay to the north-east, roughly 10 NM.
        let oak = try #require(Self.db.navaids.first { $0.associatedAirport == "KOAK" && ($0.type == .vortac || $0.type == .vorDme || $0.type == .vor) })
        let toOak = NavDatabase.bearingDistance(from: airport.position, to: oak)
        #expect(toOak.distanceNM > 6 && toOak.distanceNM < 16, "\(toOak.distanceNM) NM")
        #expect(toOak.bearingTrue > 0 && toOak.bearingTrue < 90, "\(toOak.bearingTrue)°")
    }

    @Test func nearestAirport() throws {
        let nearSFO = Geodetic(latitudeDegrees: 37.60, longitudeDegrees: -122.30, height: 0)
        #expect(Self.db.nearestAirportWithRunwayGeometry(to: nearSFO)?.ident == "KSFO")
        let nearLondon = Geodetic(latitudeDegrees: 51.48, longitudeDegrees: -0.40, height: 0)
        #expect(Self.db.nearestAirportWithRunwayGeometry(to: nearLondon)?.ident == "EGLL")
    }
}
