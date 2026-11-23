// SKYFORGE — Apache-2.0
// Pilot controls for the water scoop: the door and a tank release (a drop on a fire).
import Foundation

public struct WaterInput: Sendable, Equatable {
    /// Scoop door open. Water is taken only while the door is open and the hull is skimming the water.
    public var doorOpen: Bool = false
    /// Release the whole tank this step.
    public var release: Bool = false

    public init(doorOpen: Bool = false, release: Bool = false) {
        self.doorOpen = doorOpen
        self.release = release
    }
}
