// SKYFORGE — Apache-2.0
// Rule-based air traffic control for AI traffic. Every instruction comes from a fixed rule (phase changes,
// landing spacing, wake separation, runway occupancy) and is worded from fixed phrase templates, so the same
// traffic always gets the same words. No model, network service, API key or licensed voice is involved.
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import SFTraffic

/// Wind as the tower reports it: direction it blows from (degrees true, to the nearest 10) and speed (knots).
public struct ATCWind: Sendable, Equatable {
    public var fromDegrees: Int
    public var knots: Int

    public init(fromDegrees: Int, knots: Int) {
        let wrapped = ((fromDegrees % 360) + 360) % 360
        self.fromDegrees = ((wrapped + 5) / 10 * 10) % 360
        self.knots = max(0, knots)
    }

    /// From a NED wind vector (m/s).
    public init(windNED w: SIMD3<Double>) {
        guard w.x.isFinite, w.y.isFinite else {
            self.init(fromDegrees: 0, knots: 0)
            return
        }
        let speed = min((w.x * w.x + w.y * w.y).squareRoot(), 1_000)
        var degrees = atan2(-w.y, -w.x) * 180 / Double.pi
        if degrees < 0 { degrees += 360 }
        self.init(fromDegrees: Int((degrees / 10).rounded()) * 10, knots: Int((speed * 1.943_844).rounded()))
    }
}

/// One line the tower says, with the sim time it was said.
public struct ATCMessage: Sendable, Equatable {
    public var time: Double
    public var text: String

    public init(time: Double, text: String) {
        self.time = time
        self.text = text
    }
}

/// One instruction for this tick. A clearance to an aircraft in `TrafficSystem` is issued to it. A clearance to
/// ownship (`TrafficOwnship.id`) waits for a readback, and `readback` holds the choices the pilot picks from.
/// An advisory has no clearance.
public struct ATCInstruction: Sendable, Equatable {
    public var aircraftID: String
    public var clearance: TrafficClearance?
    public var text: String
    /// Readback choices for a clearance to ownship. Nil for advisories and for clearances to other aircraft.
    public var readback: ATCReadback?
    /// Approach control's instruction to an arrival: a vector, a direct route, a hold or a release. Nil otherwise.
    public var control: TrafficControl?

    public init(aircraftID: String, clearance: TrafficClearance?, text: String, readback: ATCReadback? = nil,
                control: TrafficControl? = nil) {
        self.aircraftID = aircraftID
        self.clearance = clearance
        self.text = text
        self.readback = readback
        self.control = control
    }
}

/// The readback choices for a clearance to ownship: the one correct readback and two wrong ones.
public struct ATCReadback: Sendable, Equatable {
    public var options: [String]
    /// Index in `options` of the correct readback.
    public var correctIndex: Int

    public init(options: [String], correctIndex: Int) {
        self.options = options
        self.correctIndex = correctIndex
    }
}

/// A clearance to ownship that is waiting for the pilot's readback.
public struct OwnshipPrompt: Sendable, Equatable {
    /// The clearance as the tower said it.
    public var text: String
    public var clearance: TrafficClearance
    /// The readbacks to choose from. Exactly one is correct.
    public var options: [String]

    public init(text: String, clearance: TrafficClearance, options: [String]) {
        self.text = text
        self.clearance = clearance
        self.options = options
    }
}

/// What the tower has confirmed and counted for ownship. Missions read this to judge the flight.
public struct OwnshipTowerStatus: Sendable, Equatable {
    /// A landing clearance was read back correctly.
    public var landingCleared: Bool
    /// A takeoff clearance was read back correctly.
    public var takeoffCleared: Bool
    /// Takeoff rolls started with no takeoff clearance read back.
    public var unauthorizedTakeoffs: Int
    /// Touchdowns with no landing clearance read back.
    public var unclearedLandings: Int

    public init(landingCleared: Bool, takeoffCleared: Bool, unauthorizedTakeoffs: Int, unclearedLandings: Int) {
        self.landingCleared = landingCleared
        self.takeoffCleared = takeoffCleared
        self.unauthorizedTakeoffs = unauthorizedTakeoffs
        self.unclearedLandings = unclearedLandings
    }
}

/// Fixed phrase templates. Numbers are read digit by digit, as pilots say them.
public enum ATCPhrase {
    static let digitWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    /// "280" becomes "two eight zero".
    public static func digits(_ text: String) -> String {
        text.compactMap { $0.wholeNumberValue }
            .filter { $0 >= 0 && $0 < 10 }
            .map { digitWords[$0] }
            .joined(separator: " ")
    }

    /// Callsign "SKY417" spoken as "SKY four one seven".
    public static func callsign(_ id: String) -> String {
        let letters = String(id.prefix { !$0.isNumber })
        let numbers = String(id.dropFirst(letters.count))
        return [letters, digits(numbers)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "runway two eight".
    public static func runway(_ designator: String) -> String {
        "runway " + digits(designator)
    }

    /// "wind two seven zero at eight", or "wind calm".
    public static func wind(_ wind: ATCWind) -> String {
        if wind.knots < 3 { return "wind calm" }
        return "wind " + digits(String(format: "%03ld", wind.fromDegrees)) + " at " + digits(String(wind.knots))
    }
}

/// Plays a line of ATC speech. Implementations must not block the simulation.
public protocol ATCSpeaker: Sendable {
    func speak(_ text: String)
}

/// The default: no sound.
public struct SilentATCSpeaker: ATCSpeaker {
    public init() {}
    public func speak(_ text: String) {}
}

#if canImport(AVFoundation)
/// Apple's built-in speech (AVSpeechSynthesizer): on-device, free, and no voice files are bundled.
public final class AVSpeechATCSpeaker: ATCSpeaker, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

    public func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
#endif

/// The tower. It watches phase changes and decides clearances from fixed rules. Callers pass in the traffic
/// picture, apply the returned clearances to `TrafficSystem`, and read the words from `log`.
public struct ATCController: Sendable {
    /// Minimum seconds between landing clearances.
    public static let landingSpacing = 75.0
    /// Minimum seconds between a heavy aircraft's landing clearance and the next light one (wake turbulence).
    public static let heavyWakeSpacing = 120.0
    /// How long after a heavy landing clearance the caution is given (s).
    public static let wakeCautionWindow = 150.0
    /// Minimum seconds between takeoff clearances.
    public static let takeoffSpacing = 60.0
    /// Most messages kept in the log.
    public static let logLimit = 40
    /// Along-runway distance (m) at which approach control stops vectoring an arrival and sends it direct to the fix.
    public static let directRange = 4_000.0
    /// Distance (m) from the approach fix within which an arrival can be held there.
    public static let holdRange = 1_500.0

    public let runwayDesignator: String
    /// Messages said so far, oldest first, capped at `logLimit`.
    public private(set) var log: [ATCMessage] = []
    private var lastPhase: [String: TrafficPhase] = [:]
    /// The controller each aircraft was last with, so a handoff is announced once.
    private var lastFacility: [String: TrafficFacility] = [:]
    private var lastLandingTime: Double?
    private var lastLandingHeavy = false
    private var lastTakeoffTime: Double?
    /// Clearances issued to ownship, read back or not. The tower's own record, so it does not repeat one.
    public private(set) var issuedToOwnship: Set<TrafficClearance> = []
    /// Clearances to ownship that the pilot read back correctly.
    public private(set) var confirmedForOwnship: Set<TrafficClearance> = []
    /// Takeoff rolls started with no takeoff clearance read back.
    public private(set) var unauthorizedTakeoffs = 0
    /// Touchdowns with no landing clearance read back.
    public private(set) var unclearedLandings = 0
    /// The clearance to ownship waiting for a readback, if any.
    private var prompt: Prompt?

    /// A clearance to ownship waiting for its readback.
    private struct Prompt: Sendable {
        var callsign: String
        var clearance: TrafficClearance
        var text: String
        var readback: ATCReadback
    }

    public init(runwayDesignator: String) {
        self.runwayDesignator = runwayDesignator
    }

    /// The last `count` messages' text, oldest first.
    public func recentLines(_ count: Int) -> [String] {
        log.suffix(max(0, count)).map { $0.text }
    }

    /// Decides this tick's instructions and records their words in `log`.
    public mutating func update(time: Double, traffic: [TrafficSnapshot], wind: ATCWind) -> [ATCInstruction] {
        var out: [ATCInstruction] = []
        let rwy = ATCPhrase.runway(runwayDesignator)
        let windText = ATCPhrase.wind(wind)

        // 1. Handoffs between controllers, then advisories on each phase change.
        for s in traffic {
            let previousFacility = lastFacility[s.id]
            if previousFacility != s.facility {
                lastFacility[s.id] = s.facility
                if let text = handoff(for: s, from: previousFacility) {
                    out.append(ATCInstruction(aircraftID: s.id, clearance: nil, text: text))
                }
            }
            let previous = lastPhase[s.id]
            guard previous != s.phase else { continue }
            lastPhase[s.id] = s.phase
            if s.id == TrafficOwnship.id, let warning = unclearedWarning(for: s) {
                out.append(ATCInstruction(aircraftID: s.id, clearance: nil, text: warning))
            }
            if let text = advisory(for: s, runway: rwy) {
                out.append(ATCInstruction(aircraftID: s.id, clearance: nil, text: text))
            }
        }
        let present = Set(traffic.map { $0.id })
        lastPhase = lastPhase.filter { present.contains($0.key) }
        lastFacility = lastFacility.filter { present.contains($0.key) }

        // 2. Landing clearance: the first base-leg arrival, once spacing and the runway allow it.
        var landingCleared = false
        let takeoffRolling = traffic.contains { $0.kind == .departure && $0.phase == .takeoffRoll }
        let arrivals = traffic
            .filter { $0.kind == .arrival && $0.phase == .base && !$0.clearedToLand }
            .sorted { $0.distanceToTouchdown < $1.distanceToTouchdown }
        // While a readback is waiting, nothing else is cleared, so the pilot's answer comes first.
        if let next = arrivals.first, !takeoffRolling, landingSpacingMet(time: time, follower: next),
           !(next.id == TrafficOwnship.id && prompt != nil) {
            let cs = ATCPhrase.callsign(next.callsign)
            let caution = lastLandingHeavy && !next.isHeavy
                && (lastLandingTime.map { time - $0 < Self.wakeCautionWindow } ?? false)
            let text = "\(cs), cleared to land \(rwy), \(windText)." + (caution ? " Caution, wake turbulence." : "")
            if next.id == TrafficOwnship.id {
                out.append(clearOwnship(.land, callsign: cs, text: text, runway: rwy, time: time))
            } else {
                out.append(ATCInstruction(aircraftID: next.id, clearance: .land, text: text))
            }
            lastLandingTime = time
            lastLandingHeavy = next.isHeavy
            landingCleared = true
        }

        // 3. Takeoff clearance: the first departure holding short, when no arrival is on or near the runway.
        let arrivalOnRunway = landingCleared || traffic.contains { a in
            a.kind == .arrival && (a.phase == .final || a.phase == .landing || (a.clearedToLand && a.phase == .base))
        }
        let takeoffSpacingMet = lastTakeoffTime.map { time - $0 >= Self.takeoffSpacing } ?? true
        if !arrivalOnRunway, !takeoffRolling, takeoffSpacingMet, prompt == nil,
           let departure = traffic.first(where: { $0.kind == .departure && $0.phase == .holdShort && !$0.clearedToTakeoff && $0.takeoffFits }) {
            let cs = ATCPhrase.callsign(departure.callsign)
            let text = "\(cs), \(rwy), cleared for takeoff, \(windText)."
            if departure.id == TrafficOwnship.id {
                out.append(clearOwnship(.takeoff, callsign: cs, text: text, runway: rwy, time: time))
            } else {
                out.append(ATCInstruction(aircraftID: departure.id, clearance: .takeoff, text: text))
            }
            lastTakeoffTime = time
        }

        // 4. Approach control. An arrival is vectored toward the approach fix, sent direct when close, held there
        // while another arrival holds the landing slot, and released when the slot is free. Only AI arrivals are
        // held or vectored. Ownship gets the advisories and no instructions of this kind.
        let slotTaken = landingCleared || traffic.contains { a in
            a.kind == .arrival && (a.phase == .base || a.phase == .final || a.phase == .landing)
        } || (lastLandingTime.map { time - $0 < Self.landingSpacing } ?? false)
        for s in traffic where s.kind == .arrival && s.id != TrafficOwnship.id && s.facility == .approach && s.phase == .inbound {
            let cs = ATCPhrase.callsign(s.callsign)
            if s.holding {
                if !slotTaken {
                    out.append(ATCInstruction(aircraftID: s.id, clearance: nil,
                                              text: "\(cs), leave the hold, proceed to the downwind.", control: .release))
                }
            } else if slotTaken, s.distanceToApproachFix < Self.holdRange {
                out.append(ATCInstruction(aircraftID: s.id, clearance: nil,
                                          text: "\(cs), hold at the approach fix, expect further clearance.", control: .hold))
            } else if s.vectored, s.alongRunway <= Self.directRange {
                out.append(ATCInstruction(aircraftID: s.id, clearance: nil,
                                          text: "\(cs), proceed direct to the downwind entry.", control: .direct))
            } else if !s.vectored, s.alongRunway > Self.directRange {
                out.append(ATCInstruction(aircraftID: s.id, clearance: nil,
                                          text: "\(cs), turn heading to the approach fix, vectors for the downwind.",
                                          control: .vectorToFix))
            }
        }

        for instruction in out {
            log.append(ATCMessage(time: time, text: instruction.text))
        }
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        return out
    }

    /// The pilot's answer to the readback prompt: `choice` indexes `ownshipPrompt.options`. Returns true when the
    /// readback is correct, which confirms the clearance. Returns false when the tower says "say again" and the
    /// prompt stays open. Returns nil when no prompt is waiting or the choice is not one of its options.
    @discardableResult
    public mutating func readback(choice: Int, time: Double) -> Bool? {
        guard let current = prompt, current.readback.options.indices.contains(choice) else { return nil }
        if choice == current.readback.correctIndex {
            confirmedForOwnship.insert(current.clearance)
            prompt = nil
            say("\(current.callsign), readback correct.", at: time)
            return true
        }
        say("\(current.callsign), negative, say again.", at: time)
        return false
    }

    /// The clearance waiting for a readback, if any.
    public var ownshipPrompt: OwnshipPrompt? {
        prompt.map { OwnshipPrompt(text: $0.text, clearance: $0.clearance, options: $0.readback.options) }
    }

    /// What the tower has confirmed and counted for ownship.
    public var ownshipStatus: OwnshipTowerStatus {
        OwnshipTowerStatus(landingCleared: confirmedForOwnship.contains(.land),
                           takeoffCleared: confirmedForOwnship.contains(.takeoff),
                           unauthorizedTakeoffs: unauthorizedTakeoffs, unclearedLandings: unclearedLandings)
    }

    /// Issues a clearance to ownship and opens a readback prompt for it.
    private mutating func clearOwnship(_ clearance: TrafficClearance, callsign: String, text: String,
                                       runway rwy: String, time: Double) -> ATCInstruction {
        let readback = readbackChoices(for: clearance, runway: rwy, time: time)
        issuedToOwnship.insert(clearance)
        prompt = Prompt(callsign: callsign, clearance: clearance, text: text, readback: readback)
        return ATCInstruction(aircraftID: TrafficOwnship.id, clearance: clearance, text: text, readback: readback)
    }

    /// The readback choices for a clearance: the correct readback and two wrong ones. The place of the correct one
    /// follows the time, so the answer is not always the same tap.
    private func readbackChoices(for clearance: TrafficClearance, runway rwy: String, time: Double) -> ATCReadback {
        let correct: String
        let wrong: [String]
        if clearance == .land {
            correct = "cleared to land \(rwy)"
            wrong = ["cleared for takeoff \(rwy)", "hold short \(rwy)"]
        } else {
            correct = "cleared for takeoff \(rwy)"
            wrong = ["cleared to land \(rwy)", "hold short \(rwy)"]
        }
        let slot = max(0, Int(time.rounded(.down))) % 3
        var options = wrong
        options.insert(correct, at: slot)
        return ATCReadback(options: options, correctIndex: slot)
    }

    /// A warning when ownship rolls or touches down with no clearance read back. Each one is counted for missions.
    private mutating func unclearedWarning(for s: TrafficSnapshot) -> String? {
        let cs = ATCPhrase.callsign(s.callsign)
        if s.phase == .takeoffRoll, !confirmedForOwnship.contains(.takeoff) {
            unauthorizedTakeoffs += 1
            return "\(cs), no takeoff clearance read back."
        }
        if s.phase == .landing, !confirmedForOwnship.contains(.land) {
            unclearedLandings += 1
            return "\(cs), no landing clearance read back."
        }
        return nil
    }

    /// Adds a line to the log, keeping the newest `logLimit`.
    private mutating func say(_ text: String, at time: Double) {
        log.append(ATCMessage(time: time, text: text))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private func landingSpacingMet(time: Double, follower: TrafficSnapshot) -> Bool {
        guard let last = lastLandingTime else { return true }
        let required = (lastLandingHeavy && !follower.isHeavy) ? Self.heavyWakeSpacing : Self.landingSpacing
        return time - last >= required
    }

    /// The words for a change of controller, or nil when there is nothing to say. A new arrival with approach is
    /// given radar contact. Later changes are handoffs: to the tower from approach or departure, or to departure.
    private func handoff(for s: TrafficSnapshot, from previous: TrafficFacility?) -> String? {
        let cs = ATCPhrase.callsign(s.callsign)
        switch (previous, s.facility) {
        case (nil, .approach):
            return "\(cs), approach, radar contact."
        case (.some(_), .tower):
            return "\(cs), contact tower."
        case (.some(_), .departure):
            return "\(cs), contact departure."
        default:
            return nil
        }
    }

    /// The words for entering a phase, or nil when the phase needs no call.
    private func advisory(for s: TrafficSnapshot, runway rwy: String) -> String? {
        let cs = ATCPhrase.callsign(s.callsign)
        switch s.phase {
        case .inbound:
            // Ownship flying back after its climb out is with departure, which gives no pattern call.
            return s.facility == .departure ? nil : "\(cs), \(rwy) in use, report downwind."
        case .downwind:
            return "\(cs), report base."
        case .base:
            return "\(cs), report final."
        case .extended:
            return "\(cs), extend downwind for spacing."
        case .landing:
            return "\(cs), \(rwy), vacate the runway when able."
        case .departing:
            return "\(cs), airborne, climb straight out."
        case .final, .holdShort, .takeoffRoll, .complete:
            return nil
        }
    }
}
