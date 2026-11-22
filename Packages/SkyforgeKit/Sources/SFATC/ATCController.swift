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
        let speed = (w.x * w.x + w.y * w.y).squareRoot()
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

/// One instruction for this tick. A clearance is also issued to `TrafficSystem`; an advisory has none.
public struct ATCInstruction: Sendable, Equatable {
    public var aircraftID: String
    public var clearance: TrafficClearance?
    public var text: String

    public init(aircraftID: String, clearance: TrafficClearance?, text: String) {
        self.aircraftID = aircraftID
        self.clearance = clearance
        self.text = text
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

    public let runwayDesignator: String
    /// Messages said so far, oldest first, capped at `logLimit`.
    public private(set) var log: [ATCMessage] = []
    private var lastPhase: [String: TrafficPhase] = [:]
    private var lastLandingTime: Double?
    private var lastLandingHeavy = false
    private var lastTakeoffTime: Double?

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

        // 1. Advisories on each phase change.
        for s in traffic {
            let previous = lastPhase[s.id]
            guard previous != s.phase else { continue }
            lastPhase[s.id] = s.phase
            if let text = advisory(for: s, runway: rwy) {
                out.append(ATCInstruction(aircraftID: s.id, clearance: nil, text: text))
            }
        }
        let present = Set(traffic.map { $0.id })
        lastPhase = lastPhase.filter { present.contains($0.key) }

        // 2. Landing clearance: the first base-leg arrival, once spacing and the runway allow it.
        let takeoffRolling = traffic.contains { $0.kind == .departure && $0.phase == .takeoffRoll }
        let arrivals = traffic
            .filter { $0.kind == .arrival && $0.phase == .base && !$0.clearedToLand }
            .sorted { $0.distanceToTouchdown < $1.distanceToTouchdown }
        if let next = arrivals.first, !takeoffRolling, landingSpacingMet(time: time, follower: next) {
            let cs = ATCPhrase.callsign(next.callsign)
            let caution = lastLandingHeavy && !next.isHeavy
                && (lastLandingTime.map { time - $0 < Self.wakeCautionWindow } ?? false)
            let text = "\(cs), cleared to land \(rwy), \(windText)." + (caution ? " Caution, wake turbulence." : "")
            out.append(ATCInstruction(aircraftID: next.id, clearance: .land, text: text))
            lastLandingTime = time
            lastLandingHeavy = next.isHeavy
        }

        // 3. Takeoff clearance: the first departure holding short, when no arrival is on or near the runway.
        let arrivalOnRunway = traffic.contains { a in
            a.kind == .arrival && (a.phase == .final || a.phase == .landing || (a.clearedToLand && a.phase == .base))
        }
        let takeoffSpacingMet = lastTakeoffTime.map { time - $0 >= Self.takeoffSpacing } ?? true
        if !arrivalOnRunway, !takeoffRolling, takeoffSpacingMet,
           let departure = traffic.first(where: { $0.kind == .departure && $0.phase == .holdShort && !$0.clearedToTakeoff }) {
            let cs = ATCPhrase.callsign(departure.callsign)
            out.append(ATCInstruction(aircraftID: departure.id, clearance: .takeoff,
                                      text: "\(cs), \(rwy), cleared for takeoff, \(windText)."))
            lastTakeoffTime = time
        }

        for instruction in out {
            log.append(ATCMessage(time: time, text: instruction.text))
        }
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        return out
    }

    private func landingSpacingMet(time: Double, follower: TrafficSnapshot) -> Bool {
        guard let last = lastLandingTime else { return true }
        let required = (lastLandingHeavy && !follower.isHeavy) ? Self.heavyWakeSpacing : Self.landingSpacing
        return time - last >= required
    }

    /// The words for entering a phase, or nil when the phase needs no call.
    private func advisory(for s: TrafficSnapshot, runway rwy: String) -> String? {
        let cs = ATCPhrase.callsign(s.callsign)
        switch s.phase {
        case .inbound:
            return "\(cs), \(rwy) in use, report downwind."
        case .downwind:
            return "\(cs), report base."
        case .base:
            return "\(cs), report final."
        case .extended:
            return "\(cs), extend downwind for spacing."
        case .landing:
            return "\(cs), \(rwy), vacate the runway when able."
        case .departing:
            return "\(cs), airborne, contact departure."
        case .final, .holdShort, .takeoffRoll, .complete:
            return nil
        }
    }
}
