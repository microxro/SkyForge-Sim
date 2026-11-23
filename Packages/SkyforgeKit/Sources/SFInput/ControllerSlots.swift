// SKYFORGE — Apache-2.0
// Hot-plug bookkeeping for gamepads and other controllers, plus merging of several sources
// into one DeviceState per frame. Pure logic, so it is tested on Linux.
import Foundation

extension InputMapper.DeviceState {
    /// Combines state from several pads or sources. An analog control keeps whichever value is
    /// farther from its resting value, so a released trigger on one pad never hides a pressed
    /// trigger on another. Pressed buttons and modifiers are unioned.
    public mutating func merge(_ other: InputMapper.DeviceState) {
        for (control, value) in other.analog {
            let rest = GamepadControl(rawValue: control)?.restValue ?? 0
            if let existing = analog[control] {
                if abs(value - rest) > abs(existing - rest) { analog[control] = value }
            } else {
                analog[control] = value
            }
        }
        pressed.formUnion(other.pressed)
        modifiers.formUnion(other.modifiers)
    }
}

/// Assigns the lowest free player slot (1, 2, 3, …) to each controller as it connects. A
/// controller that reconnects while it is still known keeps its slot. Disconnecting frees the slot.
public struct ControllerSlots<ID: Hashable & Sendable>: Sendable {
    public private(set) var assignments: [ID: Int] = [:]

    public init() {}

    /// Returns the slot for `id`, assigning the lowest free one if it is new.
    @discardableResult
    public mutating func connect(_ id: ID) -> Int {
        if let existing = assignments[id] { return existing }
        let used = Set(assignments.values)
        var slot = 1
        while used.contains(slot) { slot += 1 }
        assignments[id] = slot
        return slot
    }

    /// Frees the slot held by `id` and returns it, or nil if `id` was unknown.
    @discardableResult
    public mutating func disconnect(_ id: ID) -> Int? {
        assignments.removeValue(forKey: id)
    }

    public func slot(for id: ID) -> Int? { assignments[id] }
}
