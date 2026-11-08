// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFQuickFlight
import SFFlightModel
import SFContent
#if canImport(Darwin)
import Darwin
#endif

/// Resident memory of this process in bytes (nil where unsupported).
func residentBytes() -> Int? {
    #if os(Linux)
    guard let s = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
          let pages = s.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
    return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
    #elseif canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int(info.resident_size) : nil
    #else
    return nil
    #endif
}

/// D15 soak: 30 simulated minutes of flight over a real-world region (KMRY, offline pack), flying a
/// 22 km box that crosses the near/far height mosaics and many elevation tiles. No crash, no NaN,
/// instruments stay finite, and memory does not grow without bound.
@Suite struct SoakTests {
    @Test func thirtyMinutesOverRealTerrain() async throws {
        let a = Showcase.defaultAirport
        let p = RealWorldDetail.phone
        // Heights at the packed phone extents; imagery tiny (physics does not need it).
        let d = RealWorldDetail(nearHalf: p.nearHalf, nearStep: p.nearStep, midHalf: p.midHalf, midStep: p.midStep, farHalf: p.farHalf,
                                farStep: p.farStep, imageryNearSize: 64, imageryFarSize: 64, treeRadius: 100, maxTrees: 10)
        let region = try await RealWorldRegion.load(airport: a.ident, detail: d, transport: Showcase.transport(for: a.ident, fallback: nil), cache: nil)
        var s = QuickFlightSession(world: region, start: .final)
        let memStart = residentBytes()
        let steps = 30 * 60 * 120
        let cruiseAlt = 2_000.0                     // AMSL, clear of the Santa Lucia range
        var targetHeading = region.runwayHeading
        var maxDistance = 0.0, minAGL = Double.infinity
        for i in 0..<steps {
            // A 7.5-minute-per-leg box: turn 90° right at the start of each leg (after a 2-minute climb-out).
            if i >= 2 * 60 * 120 && (i - 2 * 60 * 120) % (450 * 120) == 0 { targetHeading += .pi / 2 }
            let e = s.state.attitude.euler
            let alt = s.state.altitude, vs = -s.state.velocityNED.z
            var dh = targetHeading - e.yaw
            dh = atan2(sin(dh), cos(dh))
            let bank = max(-0.5, min(0.5, dh * 1.2))
            let pitchTarget = max(-0.08, min(0.15, (cruiseAlt - alt) * 0.002 - vs * 0.01))
            var u = ControlInputs()
            u.aileron = max(-1, min(1, (bank - e.roll) * 2.0 - s.state.bodyRates.x * 0.3))
            u.elevator = max(-1, min(1, (pitchTarget - e.pitch) * 3.0 - s.state.bodyRates.y * 0.5 + 0.05))
            u.rudder = 0
            u.throttle = alt < cruiseAlt - 50 ? 1 : 0.75
            u.flaps = i < 60 * 120 ? 0.5 : 0
            s.setInputs(u)
            s.step()
            if i % 120 == 0 {
                let st = s.state
                let finite = st.positionNED.x.isFinite && st.positionNED.y.isFinite && st.positionNED.z.isFinite
                    && st.velocityBody.x.isFinite && st.velocityBody.y.isFinite && st.velocityBody.z.isFinite
                try #require(finite, "state finite at t=\(Double(i) / 120) s")
                let data = s.data
                try #require(data.indicatedAirspeedKt.isFinite && data.indicatedAltitudeFt.isFinite, "instruments finite at t=\(Double(i) / 120) s")
                try #require(!s.crashed, "no crash at t=\(Double(i) / 120) s (AGL \(s.heightAboveGround) m)")
                let pos = SIMD2(st.positionNED.y, st.positionNED.x)
                maxDistance = max(maxDistance, (pos * pos).sum().squareRoot())
                minAGL = min(minAGL, s.heightAboveGround)
            }
        }
        #expect(maxDistance > 15_000, "the box crossed the near mosaic and many tiles: max \(Int(maxDistance)) m from the field")
        #expect(maxDistance < p.farHalf, "stayed inside the region")
        print(String(format: "soak: 30 min, max distance %.1f km, min AGL %.0f m", maxDistance / 1_000, minAGL))
        // Process-wide memory is only meaningful when the soak runs alone (tests run in parallel):
        // CI runs `swift test --filter SoakTests` with SKYFORGE_SOAK_MEMORY=1 as a separate step.
        if ProcessInfo.processInfo.environment["SKYFORGE_SOAK_MEMORY"] == "1", let m0 = memStart, let m1 = residentBytes() {
            print("soak: resident \(m0 / 1_048_576) MB → \(m1 / 1_048_576) MB")
            #expect(m1 - m0 < 64 * 1_048_576, "memory growth \((m1 - m0) / 1_048_576) MB")
        }
    }
}
