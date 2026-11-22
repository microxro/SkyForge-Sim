import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery

@Suite struct PackCountBoundTests {
    static func header(_ magic: String, count: UInt32) -> Data {
        var d = Data(magic.utf8)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(47.53.bitPattern.littleEndian); put((-122.30).bitPattern.littleEndian); put(count.littleEndian)
        d.append(Data(count: 8))
        return d
    }

    @Test func buildingPackRejectsImpossibleCount() {
        let origin = GeoOrigin(latitude: 47.53, longitude: -122.30)
        #expect(throws: BuildingPack.ParseError.self) {
            _ = try BuildingPack.parse(Self.header("SFB1", count: UInt32.max), origin: origin)
        }
    }

    @Test func roadPackRejectsImpossibleCount() {
        let origin = GeoOrigin(latitude: 47.53, longitude: -122.30)
        #expect(throws: RoadPack.ParseError.self) {
            _ = try RoadPack.parse(Self.header("SFR1", count: UInt32.max), origin: origin)
        }
    }
}
