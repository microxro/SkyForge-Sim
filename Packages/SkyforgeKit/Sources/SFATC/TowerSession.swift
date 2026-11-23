// SKYFORGE — Apache-2.0
// One field's traffic and tower, with ownship in the tower's picture. The game and Quick Flight both step this. AI
// traffic advances on every tick, and on each decision tick the tower decides from the picture, ownship included.
// Clearances to AI aircraft are applied to the traffic. Clearances to ownship wait for the pilot's readback.
import Foundation
import SFTraffic

public struct TowerSession: Sendable {
    /// Seconds between tower decisions (s).
    public static let decisionInterval = 0.5

    public private(set) var traffic: TrafficSystem
    public private(set) var controller: ATCController
    public private(set) var ownship: OwnshipTracker
    private var clock = 0.0

    /// A field's traffic and tower. The traffic follows the field's `TrafficProfile`, so a busy field sees more
    /// movements than a short strip. `startsOnRunway` is true when ownship begins on the runway and must hold short.
    public init(runway: TrafficRunway, startsOnRunway: Bool) {
        let profile = TrafficProfile(runway: runway)
        traffic = TrafficSystem(runway: runway, seed: profile.seed, schedule: profile.schedule, fleet: profile.fleet)
        controller = ATCController(runwayDesignator: runway.designator)
        ownship = OwnshipTracker(startsOnRunway: startsOnRunway)
    }

    /// Steps the traffic every call. On each decision tick the tower decides, the AI clearances are issued, and the
    /// tick's instructions are returned for the caller to show or speak. Returns nil on the other ticks.
    @discardableResult
    public mutating func step(dt: Double, ownship report: OwnshipReport, wind: ATCWind) -> [ATCInstruction]? {
        traffic.step(dt: dt)
        _ = traffic.drainEvents()
        clock += dt
        guard clock >= Self.decisionInterval else { return nil }
        clock = 0
        var picture = traffic.snapshots
        picture.append(ownship.snapshot(of: report, system: traffic,
                                        clearedToLand: controller.issuedToOwnship.contains(.land),
                                        clearedToTakeoff: controller.issuedToOwnship.contains(.takeoff)))
        let instructions = controller.update(time: traffic.time, traffic: picture, wind: wind)
        for instruction in instructions where instruction.aircraftID != TrafficOwnship.id {
            if let clearance = instruction.clearance {
                traffic.issue(clearance, to: instruction.aircraftID)
            }
        }
        return instructions
    }

    /// The pilot's answer to the readback prompt. See `ATCController.readback(choice:time:)`.
    @discardableResult
    public mutating func readback(choice: Int) -> Bool? {
        controller.readback(choice: choice, time: traffic.time)
    }

    /// The clearance waiting for a readback, if any.
    public var prompt: OwnshipPrompt? { controller.ownshipPrompt }

    /// The tower's last three lines, oldest first.
    public var lines: [String] { controller.recentLines(3) }

    /// What the tower has confirmed and counted for ownship.
    public var status: OwnshipTowerStatus { controller.ownshipStatus }

    /// Snapshots of the AI aircraft, for the renderer and the HUD. Ownship is not in them.
    public var aircraftSnapshots: [TrafficSnapshot] { traffic.snapshots }
}
