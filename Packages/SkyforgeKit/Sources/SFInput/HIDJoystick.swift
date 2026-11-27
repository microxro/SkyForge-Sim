// SKYFORGE — Apache-2.0
// Generic HID joystick normalisation. Any device that reports HID axes, buttons and a hat switch
// maps to stable control names ("joystick.<vid>.<pid>.<instance>.axis.<n>") that bindings target.
// Platform adapters feed raw reports into HIDJoystickHub; InputMapper does the rest.
import Foundation

/// Identifies one physical device. `instance` separates two identical devices plugged in together.
public struct HIDDeviceID: Hashable, Codable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// 0 for the first device with this vendor and product, 1 for the second, and so on.
    public var instance: Int

    public init(vendorID: UInt16, productID: UInt16, instance: Int = 0) {
        self.vendorID = vendorID
        self.productID = productID
        self.instance = instance
    }

    /// Stable prefix for control names, e.g. "joystick.044f.b10a.0".
    public var controlPrefix: String {
        "joystick.\(hexWord(vendorID)).\(hexWord(productID)).\(instance)"
    }
}

private func hexWord(_ value: UInt16) -> String {
    let s = String(value, radix: 16)
    return String(repeating: "0", count: max(0, 4 - s.count)) + s
}

/// Maps a raw logical axis value to [-1, 1].
public struct HIDAxisCalibration: Codable, Sendable, Equatable {
    public var logicalMin: Double
    public var logicalMax: Double
    /// Raw value at rest. Defaults to the middle of the range.
    public var centre: Double

    public init(logicalMin: Double, logicalMax: Double, centre: Double? = nil) {
        self.logicalMin = logicalMin
        self.logicalMax = logicalMax
        self.centre = centre ?? (logicalMin + logicalMax) / 2
    }

    /// Centred axis (sticks, rudders): the rest value maps to 0 and each half scales to its own end.
    /// Invalid input (NaN, infinity, empty range) reads as 0.
    public func centred(_ raw: Double) -> Double {
        guard raw.isFinite, logicalMax > logicalMin else { return 0 }
        let c = min(max(centre, logicalMin), logicalMax)
        let v: Double
        if raw >= c {
            let span = logicalMax - c
            v = span > 0 ? (raw - c) / span : 0
        } else {
            let span = c - logicalMin
            v = span > 0 ? (raw - c) / span : 0
        }
        return min(1, max(-1, v))
    }

    /// Full-range axis (throttles, sliders): logicalMin maps to -1 and logicalMax to +1.
    /// Invalid input reads as -1, which is idle for a throttle.
    public func full(_ raw: Double) -> Double {
        guard raw.isFinite, logicalMax > logicalMin else { return -1 }
        let v = (raw - logicalMin) / (logicalMax - logicalMin) * 2 - 1
        return min(1, max(-1, v))
    }
}

/// One analog axis of a device.
public struct HIDAxisDescriptor: Codable, Sendable, Equatable {
    /// Index in the device's axis list. Part of the control name, so keep it stable.
    public var index: Int
    public var calibration: HIDAxisCalibration
    /// Throttles and sliders use the full range instead of a centred axis.
    public var fullRange: Bool

    public init(index: Int, calibration: HIDAxisCalibration, fullRange: Bool = false) {
        self.index = index
        self.calibration = calibration
        self.fullRange = fullRange
    }
}

public enum HIDHatDirection: String, Codable, Sendable, CaseIterable {
    case up, right, down, left
}

public enum HIDHat {
    /// Decodes a hat value (0 = up, then clockwise in eighths) into pressed directions.
    /// Values outside the eight positions (the HID null state) are neutral.
    public static func directions(_ value: Int, logicalMin: Int = 0) -> Set<HIDHatDirection> {
        switch value - logicalMin {
        case 0: return [.up]
        case 1: return [.up, .right]
        case 2: return [.right]
        case 3: return [.down, .right]
        case 4: return [.down]
        case 5: return [.down, .left]
        case 6: return [.left]
        case 7: return [.up, .left]
        default: return []
        }
    }
}

/// Static description of a device: what it reports and how to read it.
public struct HIDJoystickLayout: Codable, Sendable, Equatable {
    public var id: HIDDeviceID
    public var name: String
    public var axes: [HIDAxisDescriptor]
    /// Buttons are numbered from 1, matching the HID button usage numbers.
    public var buttonCount: Int
    /// Hats are numbered from 0.
    public var hatCount: Int
    public var hatLogicalMin: Int

    public init(id: HIDDeviceID, name: String, axes: [HIDAxisDescriptor], buttonCount: Int, hatCount: Int, hatLogicalMin: Int = 0) {
        self.id = id
        self.name = name
        self.axes = axes
        self.buttonCount = buttonCount
        self.hatCount = hatCount
        self.hatLogicalMin = hatLogicalMin
    }

    public func axisControl(_ index: Int) -> String { "\(id.controlPrefix).axis.\(index)" }
    public func buttonControl(_ number: Int) -> String { "\(id.controlPrefix).button.\(number)" }
    public func hatControl(_ hat: Int, _ direction: HIDHatDirection) -> String {
        "\(id.controlPrefix).hat.\(hat).\(direction.rawValue)"
    }
}

/// One raw input report from a device.
public struct HIDReport: Sendable, Equatable {
    /// Raw logical values by axis index.
    public var axes: [Int: Double]
    /// Pressed buttons, numbered from 1.
    public var buttons: Set<Int>
    /// Raw hat values by hat index.
    public var hats: [Int: Int]

    public init(axes: [Int: Double] = [:], buttons: Set<Int> = [], hats: [Int: Int] = [:]) {
        self.axes = axes
        self.buttons = buttons
        self.hats = hats
    }
}

extension HIDJoystickLayout {
    /// Turns one raw report into the values InputMapper reads: analog control values and pressed controls.
    public func controls(for report: HIDReport) -> (analog: [String: Double], pressed: Set<String>) {
        var analog: [String: Double] = [:]
        var pressed: Set<String> = []
        for axis in axes {
            guard let raw = report.axes[axis.index] else { continue }
            analog[axisControl(axis.index)] = axis.fullRange ? axis.calibration.full(raw) : axis.calibration.centred(raw)
        }
        for button in report.buttons where button >= 1 && button <= buttonCount {
            pressed.insert(buttonControl(button))
        }
        for hat in 0..<max(0, hatCount) {
            guard let value = report.hats[hat] else { continue }
            for direction in HIDHat.directions(value, logicalMin: hatLogicalMin) {
                pressed.insert(hatControl(hat, direction))
            }
        }
        return (analog, pressed)
    }
}

/// Tracks connected devices and merges their reports into one mapper input.
public struct HIDJoystickHub: Sendable {
    public private(set) var layouts: [HIDDeviceID: HIDJoystickLayout] = [:]

    public init() {}

    /// Adds a device. It gets the lowest free instance number for its vendor and product,
    /// so two identical sticks get distinct controls. Returns the assigned ID.
    @discardableResult
    public mutating func connect(_ layout: HIDJoystickLayout) -> HIDDeviceID {
        var instance = 0
        while layouts[HIDDeviceID(vendorID: layout.id.vendorID, productID: layout.id.productID, instance: instance)] != nil {
            instance += 1
        }
        var assigned = layout
        assigned.id.instance = instance
        layouts[assigned.id] = assigned
        return assigned.id
    }

    public mutating func disconnect(_ id: HIDDeviceID) {
        layouts[id] = nil
    }

    /// Merges reports from connected devices. Reports from unknown devices are ignored.
    /// Control names include the device prefix, so devices never collide.
    public func deviceState(reports: [HIDDeviceID: HIDReport]) -> InputMapper.DeviceState {
        var state = InputMapper.DeviceState()
        for (id, report) in reports {
            guard let layout = layouts[id] else { continue }
            let controls = layout.controls(for: report)
            state.analog.merge(controls.analog) { current, _ in current }
            state.pressed.formUnion(controls.pressed)
        }
        return state
    }
}
