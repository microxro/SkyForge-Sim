// SKYFORGE — Apache-2.0
// Touch layout, chase-camera gestures and their encoding for iPhone and iPad. Pure logic, tested on Linux.
// The SwiftUI controls read a `TouchLayout` to place themselves, and the flight mapper reads
// `TouchLayout.profile`, so sensitivity and the bindings screen apply to touch as they do to any device.
import Foundation

public enum TouchSide: String, Codable, Sendable, CaseIterable { case left, right }

/// Player-chosen touch control settings. Every value is clamped to its allowed range on load.
public struct TouchLayout: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public var schemaVersion: Int = TouchLayout.schemaVersion
    /// Side of the stick. The throttle sits on the other side.
    public var stickSide: TouchSide = .right
    /// Control size as a multiple of the default, 0.7 … 1.4.
    public var scale: Double = 1
    /// Control opacity, 0.2 … 1.
    public var opacity: Double = 0.85
    /// The stick returns to centre when released; false holds the last deflection.
    public var stickSpringReturn: Bool = true
    /// Stick sensitivity multiplier, 0.3 … 1.5.
    public var stickSensitivity: Double = 1
    /// Response curve on the stick, 0 (linear) … 1 (cubic).
    public var stickExpo: Double = 0.3
    /// Device tilt also drives roll and pitch. Hold the device at its neutral attitude and tap Level.
    public var tiltEnabled: Bool = false
    public var showRudder: Bool = true
    public var showFlapButtons: Bool = true

    public init() {}

    /// Every value pulled into its allowed range, so a hand-edited file cannot break the controls.
    public var clamped: TouchLayout {
        var l = self
        l.scale = Self.clamp(scale, 0.7, 1.4, fallback: 1)
        l.opacity = Self.clamp(opacity, 0.2, 1, fallback: 0.85)
        l.stickSensitivity = Self.clamp(stickSensitivity, 0.3, 1.5, fallback: 1)
        l.stickExpo = Self.clamp(stickExpo, 0, 1, fallback: 0.3)
        return l
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double, fallback: Double) -> Double {
        v.isFinite ? min(hi, max(lo, v)) : fallback
    }

    /// The touch binding profile for this layout. The stick's sensitivity and curve are applied here,
    /// so the flight mapper and the bindings screen see the same settings.
    public var profile: BindingProfile {
        let c = clamped
        var stick = AxisSettings()
        stick.innerDeadZone = 0.04
        stick.curve = .exponential(c.stickExpo)
        stick.sensitivity = c.stickSensitivity
        var p = BindingProfile.touchDefaults
        p.bindings = p.bindings.map { b in
            guard b.device == .touch, b.control == TouchControls.stickX || b.control == TouchControls.stickY else { return b }
            var out = b
            out.axis = stick
            return out
        }
        return p
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(clamped)
    }

    /// Decodes a stored layout. A newer schema is refused so an older app never misreads it.
    public static func decode(_ data: Data) throws -> TouchLayout {
        let l = try JSONDecoder().decode(TouchLayout.self, from: data)
        guard l.schemaVersion <= schemaVersion else { throw BindingProfile.ImportError.unsupportedSchema(l.schemaVersion) }
        return l.clamped
    }
}

/// Chase-camera gestures: a pinch sets the distance behind the aircraft, a two-finger drag orbits it.
public struct ChaseCameraControl: Sendable, Equatable {
    public static let minDistance = 8.0
    public static let maxDistance = 80.0
    public static let defaultDistance = 22.0
    public private(set) var distance = ChaseCameraControl.defaultDistance
    /// Orbit about the aircraft in radians (0 = directly behind).
    public private(set) var orbit = 0.0

    public init() {}

    /// A pinch scale above 1 moves the camera closer.
    public mutating func pinch(scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        distance = min(Self.maxDistance, max(Self.minDistance, distance / scale))
    }

    /// Horizontal two-finger travel in points orbits the camera (0.008 rad per point).
    public mutating func drag(points: Double) {
        guard points.isFinite else { return }
        orbit = (orbit + points * 0.008).truncatingRemainder(dividingBy: 2 * Double.pi)
    }
}
