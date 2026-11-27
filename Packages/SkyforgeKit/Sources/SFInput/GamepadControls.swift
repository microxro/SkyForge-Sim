// SKYFORGE — Apache-2.0
// Canonical gamepad control IDs. Every controller family (Xbox, DualSense/DualShock, 8BitDo,
// MFi, micro gamepads, generic HID) is normalised to these names before reaching InputMapper.
import Foundation

public enum GamepadControl: String, Codable, Sendable, CaseIterable {
    case leftStickX = "gamepad.leftStick.x"
    case leftStickY = "gamepad.leftStick.y"
    case rightStickX = "gamepad.rightStick.x"
    case rightStickY = "gamepad.rightStick.y"
    case leftTrigger = "gamepad.leftTrigger"
    case rightTrigger = "gamepad.rightTrigger"
    case buttonA = "gamepad.buttonA"
    case buttonB = "gamepad.buttonB"
    case buttonX = "gamepad.buttonX"
    case buttonY = "gamepad.buttonY"
    case leftShoulder = "gamepad.leftShoulder"
    case rightShoulder = "gamepad.rightShoulder"
    case leftStickButton = "gamepad.leftStickButton"
    case rightStickButton = "gamepad.rightStickButton"
    case dpadUp = "gamepad.dpad.up"
    case dpadDown = "gamepad.dpad.down"
    case dpadLeft = "gamepad.dpad.left"
    case dpadRight = "gamepad.dpad.right"
    case menu = "gamepad.menu"
    case options = "gamepad.options"
    case home = "gamepad.home"
    case share = "gamepad.share"

    /// Resting value of the control before the player touches it. Triggers are reported in
    /// [-1, 1] with -1 released, so they rest at -1; sticks rest at 0; buttons are not analog.
    public var restValue: Double {
        switch self {
        case .leftTrigger, .rightTrigger: return -1
        default: return 0
        }
    }

    /// Converts a trigger reported in [0, 1] (GameController, SDL and most HID) to [-1, 1].
    public static func triggerFromUnit(_ unit: Double) -> Double {
        guard unit.isFinite else { return -1 }
        return min(1, max(0, unit)) * 2 - 1
    }
}
