// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFImagery

@Suite struct AnyPointStartTests {
    @Test func acceptsAnyPointInsideMercatorRange() throws {
        let s = try AnyPointStart(latitude: -33.9, longitude: 151.2)
        #expect(s.origin == GeoOrigin(latitude: -33.9, longitude: 151.2))
    }

    @Test func rejectsPolesAndNonFiniteInput() {
        #expect(throws: AnyPointStart.Error.self) { try AnyPointStart(latitude: 89, longitude: 0) }
        #expect(throws: AnyPointStart.Error.self) { try AnyPointStart(latitude: .nan, longitude: 0) }
        #expect(throws: AnyPointStart.Error.self) { try AnyPointStart(latitude: 0, longitude: .infinity) }
    }

    @Test func normalisesLongitudeAcrossTheDateLine() throws {
        #expect(try AnyPointStart(latitude: 0, longitude: 190).longitude == -170)
        #expect(try AnyPointStart(latitude: 0, longitude: -190).longitude == 170)
        #expect(try AnyPointStart(latitude: 0, longitude: 360).longitude == 0)
    }

    @Test func distanceIsAboutOneKilometreEastAtTheEquator() throws {
        let s = try AnyPointStart(latitude: 0, longitude: 0)
        let d = s.distance(latitude: 0, longitude: 1.0 / 111.32)   // 1 km of longitude at the equator
        #expect(abs(d - 1_000) < 5)
        let o = s.localOffset(latitude: 0, longitude: 1.0 / 111.32)
        #expect(abs(o.x - 1_000) < 5 && abs(o.y) < 1)
    }
}
