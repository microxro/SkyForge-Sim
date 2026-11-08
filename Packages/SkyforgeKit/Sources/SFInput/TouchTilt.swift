// SKYFORGE — Apache-2.0
// Touch yoke/throttle, device-tilt mapping and press-to-bind capture. Pure logic, so the
// behaviour is tested on Linux; SwiftUI and CoreMotion adapters only feed these types.
import Foundation

// MARK: - Touch controls

/// Virtual stick: a touch inside a circular pad maps to (x, y) in the unit disc.
/// x + = right roll, y + = stick back (nose up), matching `FlightAxis.pitch`.
public struct TouchStick: Sendable, Equatable {
    public var center: (x: Double, y: Double) { (cx, cy) }
    public var radius: Double
    public private(set) var x = 0.0
    public private(set) var y = 0.0
    public private(set) var active = false
    private var cx: Double, cy: Double

    public init(centerX: Double, centerY: Double, radius: Double) { cx = centerX; cy = centerY; self.radius = radius }

    public static func == (a: TouchStick, b: TouchStick) -> Bool {
        a.cx == b.cx && a.cy == b.cy && a.radius == b.radius && a.x == b.x && a.y == b.y && a.active == b.active
    }

    /// Touch position in view points (y grows downward, as UIKit/SwiftUI report it).
    public mutating func touch(atX px: Double, y py: Double) {
        var dx = (px - cx) / radius, dy = (py - cy) / radius   // dy > 0 = finger below centre = pull back
        let m = (dx * dx + dy * dy).squareRoot()
        if m > 1 { dx /= m; dy /= m }
        x = dx; y = dy; active = true
    }

    /// Spring return to centre on release.
    public mutating func release() { x = 0; y = 0; active = false }
}

/// Throttle lever: vertical slider 0 (bottom) … 1 (top). Holds its value when released.
public struct TouchThrottle: Sendable, Equatable {
    public var minY: Double, maxY: Double
    public private(set) var value: Double
    public init(minY: Double, maxY: Double, value: Double = 0) { self.minY = minY; self.maxY = maxY; self.value = value }
    public mutating func touch(atY py: Double) {
        guard maxY > minY else { return }
        value = min(1, max(0, (maxY - py) / (maxY - minY)))
    }
}

public enum TouchControls {
    public static let stickX = "touch.stick.x"
    public static let stickY = "touch.stick.y"
    public static let throttle = "touch.throttle"
    public static let rudder = "touch.rudder"

    public static func deviceState(stick: TouchStick, throttle: TouchThrottle, rudder: Double = 0) -> InputMapper.DeviceState {
        InputMapper.DeviceState(analog: [stickX: stick.x, stickY: stick.y, Self.throttle: throttle.value, Self.rudder: rudder])
    }
}

// MARK: - Tilt

/// Maps the gravity vector measured in the device frame (CoreMotion convention: x right, y up
/// the screen in portrait, z out of the screen; units of g) to roll/pitch analog values.
public struct TiltMapper: Sendable, Equatable {
    public enum Orientation: String, Sendable, Codable { case portrait, landscapeLeft, landscapeRight }

    public var orientation: Orientation = .landscapeLeft
    /// Tilt (degrees) giving full deflection.
    public var maxRollDeg = 35.0
    public var maxPitchDeg = 25.0
    public var deadZoneDeg = 2.0
    /// Neutral attitude captured by `calibrate` (degrees).
    public private(set) var neutralRoll = 0.0
    public private(set) var neutralPitch = 0.0

    public init(orientation: Orientation = .landscapeLeft) { self.orientation = orientation }

    /// Device tilt angles in the screen frame as the player holds it: roll + = right side down,
    /// pitch + = top edge tipped toward the player.
    public func angles(gravity g: (x: Double, y: Double, z: Double)) -> (roll: Double, pitch: Double) {
        // Rotate the device frame into the "held" screen frame.
        let sx: Double, sy: Double
        switch orientation {
        case .portrait: sx = g.x; sy = g.y
        case .landscapeLeft: sx = -g.y; sy = g.x       // home indicator on the right
        case .landscapeRight: sx = g.y; sy = -g.x
        }
        let roll = atan2(sx, (sy * sy + g.z * g.z).squareRoot()) * 180 / .pi
        let pitch = atan2(-g.z, -sy) * 180 / .pi   // 0 upright facing the player, 90 lying face up
        return (roll, pitch)
    }

    public mutating func calibrate(gravity g: (x: Double, y: Double, z: Double)) {
        let a = angles(gravity: g)
        neutralRoll = a.roll; neutralPitch = a.pitch
    }

    /// Analog values in [-1, 1]: roll + = right, pitch + = nose up (top edge toward the player).
    public func axes(gravity g: (x: Double, y: Double, z: Double)) -> (roll: Double, pitch: Double) {
        let a = angles(gravity: g)
        func shape(_ d: Double, _ maxDeg: Double) -> Double {
            let m = abs(d)
            guard m > deadZoneDeg else { return 0 }
            return (d < 0 ? -1 : 1) * min(1, (m - deadZoneDeg) / max(1, maxDeg - deadZoneDeg))
        }
        var dp = a.pitch - neutralPitch
        if dp > 180 { dp -= 360 }; if dp < -180 { dp += 360 }
        return (shape(a.roll - neutralRoll, maxRollDeg), shape(dp, maxPitchDeg))
    }

    public static let rollControl = "tilt.roll"
    public static let pitchControl = "tilt.pitch"

    public func deviceState(gravity g: (x: Double, y: Double, z: Double)) -> InputMapper.DeviceState {
        let a = axes(gravity: g)
        return InputMapper.DeviceState(analog: [Self.rollControl: a.roll, Self.pitchControl: a.pitch])
    }
}

extension BindingProfile {
    /// Touch and tilt defaults (layered under the keyboard/gamepad defaults on iPhone/iPad).
    public static let touchDefaults = BindingProfile(name: "Touch", layer: .device, bindings: [
        Binding(device: .touch, control: TouchControls.stickX, target: .axis(.roll), axis: {
            var a = AxisSettings(); a.innerDeadZone = 0.04; a.curve = .exponential(0.3); return a }()),
        Binding(device: .touch, control: TouchControls.stickY, target: .axis(.pitch), axis: {
            var a = AxisSettings(); a.innerDeadZone = 0.04; a.curve = .exponential(0.3); return a }()),
        Binding(device: .touch, control: TouchControls.throttle, target: .axis(.throttle), axis: {
            var a = AxisSettings(); a.innerDeadZone = 0; a.outerDeadZone = 0; return a }()),   // already 0…1
        Binding(device: .touch, control: TouchControls.rudder, target: .axis(.yaw)),
        Binding(device: .tilt, control: TiltMapper.rollControl, target: .axis(.roll), axis: {
            var a = AxisSettings(); a.innerDeadZone = 0; a.smoothing = 0.08; return a }()),
        Binding(device: .tilt, control: TiltMapper.pitchControl, target: .axis(.pitch), axis: {
            var a = AxisSettings(); a.innerDeadZone = 0; a.smoothing = 0.08; return a }()),
    ])
}

// MARK: - Press-to-bind

/// Captures the next control the player moves, for the bindings screen. Digital controls must
/// be newly pressed (not held when capture began); analog controls must move ≥ `threshold`
/// from where they rested when capture began, so a drifting stick never binds itself.
public struct BindingCapture: Sendable {
    public enum Outcome: Sendable, Equatable {
        case waiting
        case captured(Binding, conflicts: [Binding])
        case cancelled
        case timedOut
    }

    public let target: BindingTarget
    public let devices: Set<DeviceClass>
    public var threshold = 0.5
    public var timeout: Double = 10
    public static let cancelControl = "key.escape"

    private var baselineAnalog: [String: Double]?
    private var baselinePressed: Set<String> = []
    private var elapsed = 0.0
    private let existing: [Binding]
    private let context: InputContext

    public init(target: BindingTarget, devices: Set<DeviceClass> = Set(DeviceClass.allCases),
                existing: [Binding] = [], context: InputContext = .flight) {
        self.target = target; self.devices = devices; self.existing = existing; self.context = context
    }

    static func device(for control: String) -> DeviceClass? {
        let prefix = control.split(separator: ".").first.map(String.init) ?? ""
        switch prefix {
        case "key": return .keyboard
        case "gamepad": return .gamepad
        case "touch": return .touch
        case "tilt": return .tilt
        case "mouse": return .mouse
        case "joystick", "hid": return .joystick
        default: return nil
        }
    }

    public mutating func feed(_ s: InputMapper.DeviceState, dt: Double) -> Outcome {
        guard let base = baselineAnalog else {
            baselineAnalog = s.analog
            baselinePressed = s.pressed
            return .waiting
        }
        if s.pressed.contains(Self.cancelControl) && !baselinePressed.contains(Self.cancelControl) { return .cancelled }
        elapsed += dt
        // New digital presses (deterministic order).
        for c in s.pressed.subtracting(baselinePressed).sorted() where c != Self.cancelControl {
            guard let dev = Self.device(for: c), devices.contains(dev) else { continue }
            if case .axis = target, dev != .keyboard { continue }   // buttons drive actions; keys may drive axes
            return finish(Binding(device: dev, control: c, modifiers: s.modifiers, context: context, target: target))
        }
        // Released keys stop counting as held, so a re-press is "new".
        baselinePressed.formIntersection(s.pressed)
        if case .axis = target {
            for (c, v) in s.analog.sorted(by: { $0.key < $1.key }) {
                guard let dev = Self.device(for: c), devices.contains(dev) else { continue }
                let rest = base[c] ?? 0
                if abs(v - rest) >= threshold {
                    var settings = AxisSettings()
                    settings.calibrationCentre = abs(rest) < 0.3 ? rest : 0
                    return finish(Binding(device: dev, control: c, context: context, target: target, axis: settings))
                }
            }
        }
        return elapsed >= timeout ? .timedOut : .waiting
    }

    private func finish(_ b: Binding) -> Outcome {
        .captured(b, conflicts: existing.filter { $0.triggerKey == b.triggerKey && $0.target != b.target })
    }
}
