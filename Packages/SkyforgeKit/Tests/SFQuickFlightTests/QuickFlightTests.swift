// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFFlightModel
import SFInput
import SFPreview

@Suite struct QuickFlightTests {
    static let world = QuickFlightWorld()

    @Test func restsOnTheRunwayWithoutInput() {
        var s = QuickFlightSession(world: Self.world, start: .runway)
        for _ in 0..<(10 * 60) { s.update(realDt: 1.0 / 60, device: .init()) }
        #expect(!s.crashed)
        #expect(s.heightAboveGround > 1.0 && s.heightAboveGround < 1.4, "AGL \(s.heightAboveGround)")
        #expect(s.data.indicatedAirspeedKt < 1)
    }

    @Test func takesOffWithTouchThrottleAndStick() {
        var s = QuickFlightSession(world: Self.world, start: .runway)
        var stick = TouchStick(centerX: 0, centerY: 0, radius: 1)
        let throttle = TouchThrottle(minY: 0, maxY: 1, value: 1)
        var maxAGL = 0.0
        for _ in 0..<(60 * 60) {
            // Rotate at 55 KIAS, then hold a gentle climb attitude.
            if s.data.indicatedAirspeedKt > 55 { stick.touch(atX: 0, y: s.data.pitchDeg < 8 ? 0.35 : 0.05) } else { stick.release() }
            s.update(realDt: 1.0 / 60, device: TouchControls.deviceState(stick: stick, throttle: throttle))
            maxAGL = max(maxAGL, s.heightAboveGround)
        }
        #expect(!s.crashed)
        #expect(maxAGL > 80, "max AGL \(maxAGL) m")   // ≈ 600 fpm after a ~20 s roll
        #expect(s.data.indicatedAirspeedKt > 50)
    }

    @Test func finalApproachStartIsFlyable() {
        var s = QuickFlightSession(world: Self.world, start: .final)
        let agl0 = s.heightAboveGround
        for _ in 0..<(5 * 120) { s.step() }
        #expect(!s.crashed)
        #expect(s.heightAboveGround > 0.5 * agl0)
        let toThreshold = Self.world.runway.threshold - SIMD2(s.positionENU.x, s.positionENU.y)
        #expect((toThreshold * Self.world.runwayDirection).sum() > 1_500)   // still short of the runway, pointing at it
    }

    @Test func divingIntoTheGroundCrashes() {
        var s = QuickFlightSession(world: Self.world, start: .final)
        var i = s.inputs
        i.elevator = -1; i.throttle = 1
        s.setInputs(i)
        for _ in 0..<(60 * 120) where !s.crashed { s.step() }
        #expect(s.crashed)
    }

    @Test func aircraftMeshIsInBodyAxes() {
        let m = QuickFlightWorld.aircraftMesh()
        #expect(m.triangleCount > 200)
        let xs = m.positions.map(\.x), ys = m.positions.map(\.y), zs = m.positions.map(\.z)
        #expect(xs.max()! > 2 && xs.min()! < -5)          // nose forward (+x), tail aft
        #expect(abs(ys.max()! - 5.5) < 0.3 && abs(ys.min()! + 5.5) < 0.3)   // 11 m span along y
        #expect(zs.max()! > 0.8)                           // wheels below (z down)
    }

    @Test func environmentMeshFitsThePhoneBudget() {
        var d = QuickFlightDetail.phone
        d.objectRadius = 500; d.nearHalfExtent = 800; d.midHalfExtent = 2_400; d.farHalfExtent = 6_000   // trimmed for test time
        let soup = Self.world.buildEnvironment(detail: d)
        #expect(soup.triangleCount > 20_000 && soup.triangleCount < 1_200_000, "\(soup.triangleCount) triangles")
        #expect(soup.material.contains(.road))
    }

    @Test func chaseCameraStaysBehindAndAboveGround() {
        let s = QuickFlightSession(world: Self.world, start: .runway)
        let c = s.chaseCamera()
        #expect(c.position.z >= Self.world.recipe.height(c.position.x, c.position.y) + 1.9)
        let toTarget = c.target - c.position
        #expect((SIMD2(toTarget.x, toTarget.y) * Self.world.runwayDirection).sum() > 0)
    }
}
