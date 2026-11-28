import Testing
import Foundation
@testable import SFInput

@Suite struct SettingsTuningTests {
    @Test func deadZoneScaleScalesInnerDeadZoneWithCap() {
        let tuned = BindingProfile.defaults.tuned(invertPitch: false, deadZoneScale: 2, touchSensitivity: 1)
        let before = BindingProfile.defaults.bindings.map { $0.axis.innerDeadZone }
        let after = tuned.bindings.map { $0.axis.innerDeadZone }
        for (b, a) in zip(before, after) {
            #expect(abs(a - min(b * 2, 0.5)) < 1e-12)
        }
    }

    @Test func invertPitchFlipsOnlyGamepadPitch() {
        let tuned = BindingProfile.defaults.tuned(invertPitch: true, deadZoneScale: 1, touchSensitivity: 1)
        for (orig, new) in zip(BindingProfile.defaults.bindings, tuned.bindings) {
            if orig.device == .gamepad, orig.target == .axis(.pitch) {
                #expect(new.axis.invert != orig.axis.invert)
            } else {
                #expect(new.axis.invert == orig.axis.invert)
            }
        }
    }

    @Test func nonFiniteSettingsFallBackToNeutral() {
        let tuned = BindingProfile.defaults.tuned(invertPitch: false, deadZoneScale: .nan, touchSensitivity: .infinity)
        for (orig, new) in zip(BindingProfile.defaults.bindings, tuned.bindings) {
            #expect(new.axis.innerDeadZone == orig.axis.innerDeadZone)
            #expect(new.axis.sensitivity == orig.axis.sensitivity)
        }
    }
}
