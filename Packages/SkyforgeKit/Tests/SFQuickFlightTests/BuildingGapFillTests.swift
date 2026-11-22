// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight

@Suite struct BuildingGapIndexTests {
    let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]

    @Test func insideAndNearbyPointsAreNotClear() {
        let index = BuildingGapIndex(footprints: [square])
        #expect(!index.isClear(SIMD2(5, 5), clearance: 30), "inside the footprint")
        #expect(!index.isClear(SIMD2(20, 5), clearance: 30), "10 m east of the outline")
        #expect(index.isClear(SIMD2(60, 5), clearance: 30), "50 m from the outline")
        #expect(index.isClear(SIMD2(-400, -400), clearance: 30), "far from every bucket")
    }

    @Test func distanceToACornerIsMeasuredToTheCorner() {
        let index = BuildingGapIndex(footprints: [square])
        // Corner (10, 10) is √200 ≈ 14.1 m from (20, 20).
        #expect(!index.isClear(SIMD2(20, 20), clearance: 15), "14.1 m from the corner, inside 15 m")
        #expect(index.isClear(SIMD2(20, 20), clearance: 13), "14.1 m from the corner, outside 13 m")
    }

    @Test func wideFootprintsAreStillChecked() {
        let wide: [SIMD2<Double>] = [SIMD2(-2_000, -2_000), SIMD2(2_000, -2_000), SIMD2(2_000, 2_000), SIMD2(-2_000, 2_000)]
        let index = BuildingGapIndex(footprints: [wide])
        #expect(!index.isClear(SIMD2(1_000, 1_000), clearance: 30), "inside a 4 km footprint")
        #expect(!index.isClear(SIMD2(2_010, 0), clearance: 30), "10 m outside a 4 km footprint")
    }
}

@Suite struct BuildingGapFillTests {
    /// Boeing Field with no OSM (offline): the fill grows houses on built-up imagery, clear of a surveyed square.
    @Test func gapHousesStayClearOfSurveyedFootprints() async throws {
        let ident = "KBFI"
        let p = RealWorldDetail.phone
        let d = RealWorldDetail(nearHalf: 1_200, nearStep: 40, midHalf: 3_000, midStep: 200, farHalf: 8_000, farStep: 1_000,
                                imageryNearSize: Int(Double(p.imageryNearSize) * 1_200 / p.nearHalf),
                                imageryFarSize: Int(Double(p.imageryFarSize) * 8_000 / p.farHalf), treeRadius: 300, maxTrees: 1_000)
        let region = try await RealWorldRegion.load(airport: ident, detail: d, transport: Showcase.transport(for: ident, fallback: nil), cache: nil,
                                                    bundledBuildings: false)
        // A surveyed 300 m square over the field centre.
        let survey: [SIMD2<Double>] = [SIMD2(-150, -150), SIMD2(150, -150), SIMD2(150, 150), SIMD2(-150, 150)]
        let index = BuildingGapIndex(footprints: [survey])
        let houses = region.proceduralBuildings(clearOf: index)
        #expect(houses.count > 50, "gap houses around the field: \(houses.count)")
        for h in houses {
            let c = OSMGeometry.centroid(h.footprint)
            #expect(index.isClear(c, clearance: 30), "house at \(c) is clear of the survey")
            for v in h.footprint {
                #expect(!(abs(v.x) <= 150 && abs(v.y) <= 150), "no corner inside the survey")
            }
        }
        #expect(region.proceduralBuildings(clearOf: index) == houses, "deterministic")
    }
}
