import Testing
import Foundation
import SFMath
@testable import SFNavData
import SFContent

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

@Suite struct SnapshotTests {
    @Test func bundledSnapshotLoads() throws {
        let m = try BundledNavData.manifest()
        let db = try BundledNavData.load()
        #expect(db.airports.count == m.files["airports"]?.rows)
        #expect(db.navaids.count == m.files["navaids"]?.rows)
        #expect(db.runways(at: "KSFO").count == 4)
        #expect(db.airport("EGLL")?.name.contains("Heathrow") == true)
        #expect(db.runways(at: "EGLL").contains { $0.hasGeometry })
    }

    struct FixtureTransport: HTTPTransport {
        let files: [String: Data]
        func get(_ url: URL) async throws -> Data {
            guard let d = files[url.deletingPathExtension().lastPathComponent] else { throw TransportError.status(404) }
            return d
        }
    }

    @Test func updaterRejectsImplausibleDownloads() async throws {
        // The fixture subset has only a handful of rows, far outside ±20 % of the bundled baseline.
        let files = ["airports", "runways", "navaids"].reduce(into: [String: Data]()) { $0[$1] = Data(NavDataTests.load($1).utf8) }
        let updater = AirportDatabaseUpdater(transport: FixtureTransport(files: files), baseline: try BundledNavData.manifest())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfnav-\(UUID().uuidString)")
        await #expect(throws: SnapshotError.self) { _ = try await updater.update(into: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func updaterInstallsPlausibleDownloadsAtomically() async throws {
        let files = ["airports", "runways", "navaids"].reduce(into: [String: Data]()) { $0[$1] = Data(NavDataTests.load($1).utf8) }
        // Baseline matching the fixture's own filtered counts.
        let fixtureDB = NavDataTests.db
        let baseline = SnapshotManifest(source: "test", built: "test", files: [
            "airports": .init(rows: fixtureDB.airports.values.filter { !["closed", "heliport", "balloonport"].contains($0.type) }.count, rawBytes: 0, compressedBytes: 0),
            "runways": .init(rows: fixtureDB.runwaysByAirport.values.reduce(0) { $0 + $1.filter { !$0.closed }.count }, rawBytes: 0, compressedBytes: 0),
            "navaids": .init(rows: fixtureDB.navaids.count, rawBytes: 0, compressedBytes: 0),
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfnav-\(UUID().uuidString)")
        let db = try await AirportDatabaseUpdater(transport: FixtureTransport(files: files), baseline: baseline).update(into: dir)
        #expect(db.airport("KSFO") != nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("runways.csv").path))
    }
}
