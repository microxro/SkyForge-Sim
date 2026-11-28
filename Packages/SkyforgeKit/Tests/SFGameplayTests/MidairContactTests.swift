// SKYFORGE — Apache-2.0
// Midair contact: ownship inside a live AI aircraft's hit sphere plus the contact radius.
import Testing
import Foundation
import SFMath
@testable import SFGameplay

@Suite struct MidairContactTests {
    @Test func contactUsesTheTargetRadiusPlusTheContactRadius() {
        let t = AITarget(id: "x", role: .hostile, position: SIMD3(100, 0, 0), heading: 0, speed: 100)
        let reach = t.radius + GameplayDirector.contactRadius
        #expect(GameplayDirector.inContact(position: SIMD3(100 - reach + 1, 0, 0), target: t))
        #expect(!GameplayDirector.inContact(position: SIMD3(100 - reach - 1, 0, 0), target: t))
    }

    @Test func contactIsThreeDimensional() {
        let t = AITarget(id: "y", role: .friendly, position: SIMD3(0, 0, -1_000), heading: 0, speed: 100)
        #expect(GameplayDirector.inContact(position: SIMD3(0, 0, -1_000 + 10), target: t))
        #expect(!GameplayDirector.inContact(position: SIMD3(0, 0, -1_000 + 60), target: t))
    }
}
