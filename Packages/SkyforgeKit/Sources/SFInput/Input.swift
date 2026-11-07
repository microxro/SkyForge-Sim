// SKYFORGE — Apache-2.0
// Device-independent input: actions/axes, bindings, response curves, layered profiles, JSON import/export.
import Foundation

public enum FlightAxis: String, Codable, Sendable, CaseIterable {
    case pitch, roll, yaw, throttle, flaps, brakes, elevatorTrim
}

public enum FlightAction: String, Codable, Sendable, CaseIterable {
    case flapsUp, flapsDown, gearToggle, parkingBrake, pause, cameraNext, trimUp, trimDown, resetFlight
}

public enum DeviceClass: String, Codable, Sendable, CaseIterable {
    case keyboard, gamepad, touch, tilt, mouse, joystick
}

public enum InputContext: String, Codable, Sendable, CaseIterable {
    case flight, menu, photoMode
}

public enum Modifier: String, Codable, Sendable, Hashable {
    case shift, control, option, command
}

/// Response curve applied after dead zones.
public enum ResponseCurve: Codable, Sendable, Equatable {
    case linear
    /// Blend between linear (0) and cubic (1).
    case exponential(Double)
    /// Five control points (outputs at inputs 0, 0.25, 0.5, 0.75, 1) on the positive half, mirrored.
    case spline([Double])

    public func apply(_ x: Double) -> Double {
        let s: Double = x < 0 ? -1 : 1
        let a = min(1, abs(x))
        switch self {
        case .linear: return x
        case .exponential(let k):
            let kk = min(1, max(0, k))
            return s * ((1 - kk) * a + kk * a * a * a)
        case .spline(let p):
            guard p.count == 5 else { return x }
            // Monotone piecewise-cubic Hermite (Fritsch–Carlson) through the five points.
            let xs = [0.0, 0.25, 0.5, 0.75, 1.0]
            var d = [Double](repeating: 0, count: 4)
            for i in 0..<4 { d[i] = (p[i + 1] - p[i]) / 0.25 }
            var m = [Double](repeating: 0, count: 5)
            m[0] = d[0]; m[4] = d[3]
            for i in 1..<4 { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
            for i in 0..<4 where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
            let i = min(3, Int(a / 0.25))
            let h = 0.25, t = (a - xs[i]) / h
            let t2 = t * t, t3 = t2 * t
            let y = (2 * t3 - 3 * t2 + 1) * p[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * p[i + 1] + (t3 - t2) * h * m[i + 1]
            return s * y
        }
    }
}

/// Per-binding axis processing settings.
public struct AxisSettings: Codable, Sendable, Equatable {
    public var innerDeadZone = 0.05
    public var outerDeadZone = 0.02
    public var curve: ResponseCurve = .linear
    public var invert = false
    public var sensitivity = 1.0
    /// Exponential smoothing time constant (s); 0 = none.
    public var smoothing = 0.0
    /// Calibration: raw centre and half-range (for joysticks that do not centre at 0).
    public var calibrationCentre = 0.0
    public var calibrationRange = 1.0
    /// Unipolar axes (throttle) map [-1,1] -> [0,1] after processing.
    public var unipolar = false
    public init() {}

    /// Processes a raw value in [-1, 1].
    public func process(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        var x = (raw - calibrationCentre) / max(calibrationRange, 1e-6)
        x = min(1, max(-1, x))
        if invert { x = -x }
        let a = abs(x)
        let usable = max(1e-6, 1 - innerDeadZone - outerDeadZone)
        let scaled = a <= innerDeadZone ? 0 : min(1, (a - innerDeadZone) / usable)
        var y = curve.apply(x < 0 ? -scaled : scaled) * sensitivity
        y = min(1, max(-1, y))
        return unipolar ? (y + 1) / 2 : y
    }
}

public enum BindingTarget: Codable, Sendable, Equatable, Hashable {
    case axis(FlightAxis)
    case action(FlightAction)
}

public struct Binding: Codable, Sendable, Equatable {
    public var device: DeviceClass
    public var control: String               // e.g. "key.w", "gamepad.leftStick.y"
    public var modifiers: Set<Modifier> = []
    public var context: InputContext = .flight
    public var aircraftID: String? = nil
    public var target: BindingTarget
    public var axis = AxisSettings()
    /// For digital controls driving an axis (keyboard): value applied while held.
    public var digitalValue: Double = 1

    public init(device: DeviceClass, control: String, modifiers: Set<Modifier> = [], context: InputContext = .flight,
                aircraftID: String? = nil, target: BindingTarget, axis: AxisSettings = AxisSettings(), digitalValue: Double = 1) {
        self.device = device; self.control = control; self.modifiers = modifiers; self.context = context
        self.aircraftID = aircraftID; self.target = target; self.axis = axis; self.digitalValue = digitalValue
    }

    var triggerKey: String {
        "\(device.rawValue)|\(control)|\(modifiers.map(\.rawValue).sorted().joined(separator: "+"))|\(context.rawValue)|\(aircraftID ?? "*")"
    }
}

public enum ProfileLayer: String, Codable, Sendable, CaseIterable, Comparable {
    case global, device, aircraft, context
    var rank: Int { ProfileLayer.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: ProfileLayer, b: ProfileLayer) -> Bool { a.rank < b.rank }
}

public struct BindingProfile: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public var schemaVersion: Int = BindingProfile.schemaVersion
    public var name: String
    public var layer: ProfileLayer
    public var bindings: [Binding]

    public init(name: String, layer: ProfileLayer, bindings: [Binding]) {
        self.name = name; self.layer = layer; self.bindings = bindings
    }

    public func exportJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public enum ImportError: Error, Equatable { case unsupportedSchema(Int) }

    public static func importJSON(_ data: Data) throws -> BindingProfile {
        let p = try JSONDecoder().decode(BindingProfile.self, from: data)
        guard p.schemaVersion <= schemaVersion else { throw ImportError.unsupportedSchema(p.schemaVersion) }
        return p
    }

    /// Default profile: keyboard + gamepad.
    public static let defaults = BindingProfile(name: "Default", layer: .global, bindings: [
        Binding(device: .keyboard, control: "key.w", target: .axis(.pitch), digitalValue: -0.6),
        Binding(device: .keyboard, control: "key.s", target: .axis(.pitch), digitalValue: 0.6),
        Binding(device: .keyboard, control: "key.a", target: .axis(.roll), digitalValue: -0.6),
        Binding(device: .keyboard, control: "key.d", target: .axis(.roll), digitalValue: 0.6),
        Binding(device: .keyboard, control: "key.q", target: .axis(.yaw), digitalValue: -0.6),
        Binding(device: .keyboard, control: "key.e", target: .axis(.yaw), digitalValue: 0.6),
        Binding(device: .keyboard, control: "key.f", target: .action(.flapsDown)),
        Binding(device: .keyboard, control: "key.f", modifiers: [.shift], target: .action(.flapsUp)),
        Binding(device: .keyboard, control: "key.space", target: .action(.pause)),
        Binding(device: .keyboard, control: "key.c", target: .action(.cameraNext)),
        Binding(device: .gamepad, control: "gamepad.leftStick.y", target: .axis(.pitch), axis: {
            var a = AxisSettings(); a.curve = .exponential(0.4); a.invert = true; return a }()),
        Binding(device: .gamepad, control: "gamepad.leftStick.x", target: .axis(.roll), axis: {
            var a = AxisSettings(); a.curve = .exponential(0.4); return a }()),
        Binding(device: .gamepad, control: "gamepad.rightStick.x", target: .axis(.yaw)),
        Binding(device: .gamepad, control: "gamepad.rightTrigger", target: .axis(.throttle), axis: {
            var a = AxisSettings(); a.innerDeadZone = 0.02; return a }()),
        Binding(device: .gamepad, control: "gamepad.buttonB", target: .action(.flapsDown)),
        Binding(device: .gamepad, control: "gamepad.buttonX", target: .action(.flapsUp)),
    ])
}

/// Resolves bindings across layered profiles and turns raw device state into axis values and actions.
public struct InputMapper: Sendable {
    public var profiles: [BindingProfile]
    private var smoothed: [FlightAxis: Double] = [:]

    public init(profiles: [BindingProfile]) { self.profiles = profiles }

    /// Effective bindings: for identical triggers, the higher layer wins (global < device < aircraft < context).
    public func effectiveBindings(context: InputContext, aircraftID: String?) -> [Binding] {
        var byTrigger: [String: (ProfileLayer, Binding)] = [:]
        var order: [String] = []
        for p in profiles.sorted(by: { $0.layer < $1.layer }) {
            for b in p.bindings where b.context == context && (b.aircraftID == nil || b.aircraftID == aircraftID) {
                let key = "\(b.device.rawValue)|\(b.control)|\(b.modifiers.map(\.rawValue).sorted().joined(separator: "+"))"
                if byTrigger[key] == nil { order.append(key) }
                if let existing = byTrigger[key], existing.0 > p.layer { continue }
                byTrigger[key] = (p.layer, b)
            }
        }
        return order.compactMap { byTrigger[$0]?.1 }
    }

    /// Bindings in the same profile and context whose trigger drives more than one target.
    public static func conflicts(in profile: BindingProfile) -> [(Binding, Binding)] {
        var seen: [String: Binding] = [:]
        var out: [(Binding, Binding)] = []
        for b in profile.bindings {
            if let a = seen[b.triggerKey], a.target != b.target { out.append((a, b)) } else { seen[b.triggerKey] = b }
        }
        return out
    }

    public struct Output: Sendable, Equatable {
        public var axes: [FlightAxis: Double] = [:]
        public var actions: Set<FlightAction> = []
    }

    /// Raw device state: analog control values in [-1,1] and pressed digital controls.
    public struct DeviceState: Sendable {
        public var analog: [String: Double] = [:]
        public var pressed: Set<String> = []
        public var modifiers: Set<Modifier> = []
        public init(analog: [String: Double] = [:], pressed: Set<String> = [], modifiers: Set<Modifier> = []) {
            self.analog = analog; self.pressed = pressed; self.modifiers = modifiers
        }
    }

    /// Evaluates one frame. Analog sources for the same axis use the largest magnitude; digital sources add.
    public mutating func evaluate(_ state: DeviceState, context: InputContext = .flight, aircraftID: String? = nil, dt: Double = 1.0 / 60) -> Output {
        var out = Output()
        var analogBest: [FlightAxis: Double] = [:]
        var digitalSum: [FlightAxis: Double] = [:]
        var smoothingFor: [FlightAxis: Double] = [:]
        for b in effectiveBindings(context: context, aircraftID: aircraftID) {
            switch b.target {
            case .axis(let ax):
                if let raw = state.analog[b.control] {
                    let v = b.axis.process(raw)
                    if abs(v) >= abs(analogBest[ax] ?? 0) { analogBest[ax] = v }
                    smoothingFor[ax] = max(smoothingFor[ax] ?? 0, b.axis.smoothing)
                } else if state.pressed.contains(b.control) && b.modifiers.isSubset(of: state.modifiers) {
                    digitalSum[ax, default: 0] += b.digitalValue
                }
            case .action(let act):
                // Exact modifier match so "F" and "Shift+F" are distinct.
                if state.pressed.contains(b.control) && b.modifiers == state.modifiers { out.actions.insert(act) }
            }
        }
        for ax in Set(analogBest.keys).union(digitalSum.keys) {
            let target = min(1, max(-1, (analogBest[ax] ?? 0) + (digitalSum[ax] ?? 0)))
            let tau = smoothingFor[ax] ?? 0
            let prev = smoothed[ax] ?? target
            let v = tau > 0 ? prev + (target - prev) * min(1, dt / tau) : target
            smoothed[ax] = v
            out.axes[ax] = v
        }
        return out
    }
}
