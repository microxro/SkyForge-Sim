// SKYFORGE — Apache-2.0
// Applies the Controls settings (dead zones, pitch inversion, touch and tilt sensitivity) to a binding profile.
import Foundation

extension BindingProfile {
    /// A copy of this profile with the player's control settings applied. Non-finite inputs fall back to neutral.
    public func tuned(invertPitch: Bool, deadZoneScale: Double, touchSensitivity: Double) -> BindingProfile {
        let dz = deadZoneScale.isFinite ? min(max(deadZoneScale, 0), 3) : 1
        let touch = touchSensitivity.isFinite ? min(max(touchSensitivity, 0.1), 3) : 1
        var out = self
        out.bindings = bindings.map { b in
            var b = b
            var a = b.axis
            a.innerDeadZone = min(a.innerDeadZone * dz, 0.5)
            if invertPitch, b.device == .gamepad, b.target == .axis(.pitch) {
                a.invert.toggle()
            }
            if b.device == .touch || b.device == .tilt {
                a.sensitivity *= touch
            }
            b.axis = a
            return b
        }
        return out
    }
}
