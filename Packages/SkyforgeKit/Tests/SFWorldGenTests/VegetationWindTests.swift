// SKYFORGE — Apache-2.0
import Testing
import simd
@testable import SFWorldGen

@Suite("Vegetation wind uniform")
struct VegetationWindTests {
    @Test func eastWindMapsToEastDirection() {
        // NED: no north, 10 m/s east (y). Air moves east, so ENU direction is (1, 0).
        let u = VegetationWind.uniform(windNED: SIMD3(0, 10, 0))
        #expect(abs(u.x - 1) < 1e-5 && abs(u.y) < 1e-5)
        #expect(abs(u.z - 10) < 1e-5)
        #expect(u.w == 0)
    }

    @Test func northWindMapsToNorthDirection() {
        let u = VegetationWind.uniform(windNED: SIMD3(4, 0, 0))
        #expect(abs(u.x) < 1e-5 && abs(u.y - 1) < 1e-5)
        #expect(abs(u.z - 4) < 1e-5)
    }

    @Test func calmAirHasZeroSpeedAndSafeDirection() {
        let u = VegetationWind.uniform(windNED: .zero)
        #expect(u.z == 0)
        #expect(u.x.isFinite && u.y.isFinite)
    }

    @Test func gustinessIsClampedAndScalesWithGust() {
        let none = VegetationWind.uniform(windNED: SIMD3(0, 5, 0), gustMps: 0)
        let some = VegetationWind.uniform(windNED: SIMD3(0, 5, 0), gustMps: 2)
        let huge = VegetationWind.uniform(windNED: SIMD3(0, 5, 0), gustMps: 100)
        #expect(none.w == 0)
        #expect(some.w > 0 && some.w < 1)
        #expect(huge.w == 1)
    }
}
