// SKYFORGE — Apache-2.0
// Keyboard and mouse contract: key.* and mouse.* IDs, held keyboard positions, mouse yoke and
// scroll routing, and the default PC-style profile. Pure Swift so it is testable on Linux.
import Foundation

/// Canonical keyboard control IDs. They name physical key positions (HID usage), so a layout such as
/// AZERTY keeps WASD on the same keys as QWERTY. Platform adapters map these to GCKeyCode.
public enum KeyboardKeyID {
    public static let letters: [String] = "abcdefghijklmnopqrstuvwxyz".map { "key.\($0)" }
    public static let digits: [String] = (0...9).map { "key.\($0)" }
    public static let functionKeys: [String] = (1...12).map { "key.f\($0)" }
    public static let named: [String] = [
        "space", "escape", "return", "tab", "backspace", "capsLock", "insert", "delete", "home", "end",
        "pageUp", "pageDown", "up", "down", "left", "right", "minus", "equal", "leftBracket", "rightBracket",
        "backslash", "semicolon", "quote", "grave", "comma", "period", "slash",
    ].map { "key.\($0)" }
    public static let keypad: [String] = (0...9).map { "key.keypad\($0)" } + [
        "key.keypadDecimal", "key.keypadPlus", "key.keypadMinus", "key.keypadMultiply", "key.keypadDivide", "key.keypadEnter",
    ]
    public static let modifiers: [String] = [
        "key.leftShift", "key.rightShift", "key.leftControl", "key.rightControl",
        "key.leftOption", "key.rightOption", "key.leftCommand", "key.rightCommand",
    ]
    /// Every keyboard control ID an adapter reports.
    public static let all: [String] = letters + digits + functionKeys + named + keypad + modifiers
}

/// Mouse and pointer control IDs. Buttons are digital; yoke values are analog.
public enum MouseControlID {
    public static let left = "mouse.left"
    public static let right = "mouse.right"
    public static let middle = "mouse.middle"
    /// Mouse yoke: positive `yokeX` is right, positive `yokeY` is up (pointer moved up).
    public static let yokeX = "mouse.yoke.x"
    public static let yokeY = "mouse.yoke.y"
}

/// Analog IDs for keyboard and scroll positions held by an adapter. Trigger convention: throttle rests at -1.
public enum KeyHoldID {
    public static let throttle = "key.hold.throttle"
    public static let trim = "key.hold.trim"

    /// The analog ID that carries a held position for an axis, if the keyboard drives it.
    public static func analogID(for axis: FlightAxis) -> String? {
        switch axis {
        case .throttle: return throttle
        case .elevatorTrim: return trim
        default: return nil
        }
    }
}

/// A position that moves while a key is held (rate per second) or by a step per scroll unit.
/// Values are clamped to [-1, 1]. Starts at `rest`.
public struct HeldAxis: Sendable, Equatable {
    public let rest: Double
    public private(set) var value: Double

    public init(rest: Double = 0) {
        self.rest = rest
        value = rest
    }

    public mutating func hold(rate: Double, dt: Double) {
        guard rate.isFinite, dt.isFinite, dt >= 0 else { return }
        value = Self.clamp(value + rate * dt)
    }

    public mutating func step(_ delta: Double) {
        guard delta.isFinite else { return }
        value = Self.clamp(value + delta)
    }

    public mutating func reset() { value = rest }

    static func clamp(_ x: Double) -> Double { min(1, max(-1, x)) }
}

/// One held-key rule: while `key` is down, `axis` moves at `rate` per second.
public struct KeyHold: Sendable, Equatable {
    public let key: String
    public let axis: FlightAxis
    public let rate: Double

    public init(key: String, axis: FlightAxis, rate: Double) {
        self.key = key; self.axis = axis; self.rate = rate
    }

    /// Default held keys: throttle (= and keypad +, - and keypad -), trim ( ] and [ ).
    public static let defaults: [KeyHold] = [
        KeyHold(key: "key.equal", axis: .throttle, rate: 0.8),
        KeyHold(key: "key.keypadPlus", axis: .throttle, rate: 0.8),
        KeyHold(key: "key.minus", axis: .throttle, rate: -0.8),
        KeyHold(key: "key.keypadMinus", axis: .throttle, rate: -0.8),
        KeyHold(key: "key.rightBracket", axis: .elevatorTrim, rate: 0.5),
        KeyHold(key: "key.leftBracket", axis: .elevatorTrim, rate: -0.5),
    ]
}

/// Mouse yoke: pointer movement while engaged moves the yoke to a held position. It recentres when released.
public struct MouseYoke: Sendable, Equatable {
    /// Pointer distance in points for a full deflection.
    public var pointsToFull: Double = 180
    /// Recentring rate per second once released.
    public var recentreRate: Double = 3
    public private(set) var x = 0.0
    public private(set) var y = 0.0

    public init() {}

    /// `dy` is positive when the pointer moves up.
    public mutating func update(dx: Double, dy: Double, engaged: Bool, dt: Double) {
        guard dx.isFinite, dy.isFinite, dt.isFinite, dt >= 0, pointsToFull > 0 else { return }
        if engaged {
            x = HeldAxis.clamp(x + dx / pointsToFull)
            y = HeldAxis.clamp(y + dy / pointsToFull)
        } else {
            let k = min(1, recentreRate * dt)
            x -= x * k
            y -= y * k
            if abs(x) < 1e-4 { x = 0 }
            if abs(y) < 1e-4 { y = 0 }
        }
    }
}

/// Which axis a scroll wheel drives, and how far one scroll unit moves it.
public enum ScrollRouting {
    public static func route(for modifiers: Set<Modifier>) -> (axis: FlightAxis, step: Double)? {
        if modifiers.isEmpty { return (.throttle, 0.05) }
        if modifiers == [.option] { return (.elevatorTrim, 0.02) }
        return nil
    }
}

extension AxisSettings {
    /// Exact pass-through: no dead zones, so held and yoke values reach the axis unchanged.
    static func exact(invert: Bool = false, unipolar: Bool = false) -> AxisSettings {
        var a = AxisSettings()
        a.innerDeadZone = 0
        a.outerDeadZone = 0
        a.invert = invert
        a.unipolar = unipolar
        return a
    }
}

extension BindingProfile {
    /// Default keyboard and mouse bindings. Layered above `.defaults`; the mapper gets `keyboardMouseDefaults` in its list.
    /// Pitch and roll on WASD come from `.defaults`. Held throttle and trim come from `KeyHold.defaults` via the adapter.
    public static let keyboardMouseDefaults = BindingProfile(name: "Keyboard and mouse", layer: .device, bindings: [
        Binding(device: .keyboard, control: "key.comma", target: .axis(.yaw), digitalValue: -0.6),
        Binding(device: .keyboard, control: "key.period", target: .axis(.yaw), digitalValue: 0.6),
        Binding(device: .keyboard, control: "key.b", target: .axis(.brakes)),
        Binding(device: .keyboard, control: KeyHoldID.throttle, target: .axis(.throttle), axis: .exact(unipolar: true)),
        Binding(device: .keyboard, control: KeyHoldID.trim, target: .axis(.elevatorTrim), axis: .exact()),
        Binding(device: .mouse, control: MouseControlID.yokeX, target: .axis(.roll), axis: .exact()),
        Binding(device: .mouse, control: MouseControlID.yokeY, target: .axis(.pitch), axis: .exact(invert: true)),
    ])
}
