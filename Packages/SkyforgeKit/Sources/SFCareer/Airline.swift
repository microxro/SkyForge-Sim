// SKYFORGE — Apache-2.0
// Airline career: scheduled routes, on-time and passenger-comfort scoring, rank progression and SOP checklists.
// Pure data and pure functions. A scheduled route is a `Job`, so it flies through the existing job pipeline
// (accept, settle, pay). The airline layer adds reputation, rank and SOP scoring on top of that settlement.
import Foundation
import SFMath

// MARK: - Rank

/// Airline rank. Gates which aircraft a pilot may fly on scheduled legs and how far a sector may be.
public enum AirlineRank: Int, Codable, Sendable, CaseIterable, Comparable {
    case cadet, firstOfficer, regionalCaptain, seniorCaptain

    public static func < (a: AirlineRank, b: AirlineRank) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .cadet: return "Cadet First Officer"
        case .firstOfficer: return "First Officer"
        case .regionalCaptain: return "Regional Captain"
        case .seniorCaptain: return "Senior Captain"
        }
    }

    /// Largest passenger-carrying aircraft (total seats, pilot included) this rank may fly on a scheduled leg.
    /// Larger types need their own catalog entries first; until then the top rank shares the regional seat limit.
    public var maxSeats: Int {
        switch self {
        case .cadet, .firstOfficer: return 3
        case .regionalCaptain, .seniorCaptain: return 6
        }
    }

    /// Longest sector (km) offered at this rank.
    public var maxSectorKm: Double {
        switch self {
        case .cadet: return 350
        case .firstOfficer: return 700
        case .regionalCaptain, .seniorCaptain: return 1_500
        }
    }

    /// Scheduled legs completed before this rank is reached (the rank below must be reached first).
    public var legsRequired: Int {
        switch self {
        case .cadet: return 0
        case .firstOfficer: return 5
        case .regionalCaptain: return 15
        case .seniorCaptain: return 40
        }
    }

    /// Reputation (0...100) needed alongside the legs to reach this rank.
    public var reputationRequired: Double {
        switch self {
        case .cadet: return 0
        case .firstOfficer: return 40
        case .regionalCaptain: return 60
        case .seniorCaptain: return 75
        }
    }

    public var next: AirlineRank? { AirlineRank(rawValue: rawValue + 1) }

    /// Pilot rank (XP progression in Progression.swift) needed before this airline rank may fly scheduled legs.
    /// Airline rank is a separate track on purpose: it counts scheduled legs and reputation, not every flight.
    public var minPilotRank: PilotRank {
        switch self {
        case .cadet, .firstOfficer: return .privatePilot
        case .regionalCaptain, .seniorCaptain: return .commercial
        }
    }

    /// Whether a pilot at this rank may fly the aircraft on a scheduled leg. Military types never fly scheduled legs.
    public func allows(_ aircraft: HangarAircraft) -> Bool {
        !aircraft.isMilitary && aircraft.seats <= maxSeats
    }
}

// MARK: - Career record

/// The pilot's airline record. Stored inside `CareerState`, so old saves decode with a fresh record.
public struct AirlineCareer: Codable, Sendable, Equatable {
    public static let maxLegs = 10_000_000
    public var rank: AirlineRank = .cadet
    /// Airline reputation, 0...100. Starts at 50 and moves with every scheduled leg.
    public var reputation: Double = 50
    public var legsFlown = 0
    public var legsOnTime = 0
    public var bestLegScore: Double = 0

    public init() {}

    enum CodingKeys: String, CodingKey { case rank, reputation, legsFlown, legsOnTime, bestLegScore }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        rank = try c.decodeIfPresent(AirlineRank.self, forKey: .rank) ?? .cadet
        reputation = try c.decodeIfPresent(Double.self, forKey: .reputation) ?? 50
        legsFlown = try c.decodeIfPresent(Int.self, forKey: .legsFlown) ?? 0
        legsOnTime = try c.decodeIfPresent(Int.self, forKey: .legsOnTime) ?? 0
        bestLegScore = try c.decodeIfPresent(Double.self, forKey: .bestLegScore) ?? 0
        sanitize()
    }

    /// Clamps every field. Rank can never be ahead of the legs and reputation that earned it.
    public mutating func sanitize() {
        reputation = reputation.isFinite ? min(max(reputation, 0), 100) : 50
        legsFlown = min(max(legsFlown, 0), Self.maxLegs)
        legsOnTime = min(max(legsOnTime, 0), legsFlown)
        bestLegScore = bestLegScore.isFinite ? min(max(bestLegScore, 0), 100) : 0
        rank = min(rank, Self.earnedRank(legs: legsFlown, reputation: reputation))
    }

    /// The highest rank whose leg and reputation requirements are both met.
    public static func earnedRank(legs: Int, reputation: Double) -> AirlineRank {
        AirlineRank.allCases.last { legs >= $0.legsRequired && reputation >= $0.reputationRequired } ?? .cadet
    }

    /// Fraction of scheduled legs flown on time, 0...1.
    public var onTimeRatio: Double { legsFlown == 0 ? 0 : Double(legsOnTime) / Double(legsFlown) }
}

// MARK: - SOP checklist

public enum FlightPhase: String, Codable, Sendable, CaseIterable {
    case preflight, taxi, takeoff, cruise, descent, approach, landing, shutdown
}

public struct SOPStep: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var phase: FlightPhase
    public var title: String
    /// Required steps carry most of the SOP score. Optional steps are a small bonus.
    public var required: Bool
}

public enum SOPChecklist {
    /// The standard airline checklist, in flight order. Ids are stable: saved runs refer to them.
    public static let standard: [SOPStep] = [
        .init(id: "pre.weather", phase: .preflight, title: "Check weather and NOTAMs", required: true),
        .init(id: "pre.fuel", phase: .preflight, title: "Confirm fuel for route plus reserve", required: true),
        .init(id: "pre.load", phase: .preflight, title: "Confirm load and balance", required: true),
        .init(id: "pre.cabin", phase: .preflight, title: "Brief passengers", required: false),
        .init(id: "taxi.controls", phase: .taxi, title: "Check flight controls and brakes", required: true),
        .init(id: "to.flaps", phase: .takeoff, title: "Set flaps and trim for takeoff", required: true),
        .init(id: "to.speeds", phase: .takeoff, title: "Confirm takeoff speeds", required: true),
        .init(id: "cruise.fuel", phase: .cruise, title: "Check fuel burn against plan", required: false),
        .init(id: "desc.brief", phase: .descent, title: "Brief the approach", required: true),
        .init(id: "app.stable", phase: .approach, title: "Stabilised approach by 500 ft", required: true),
        .init(id: "land.check", phase: .landing, title: "Complete the landing checklist", required: true),
        .init(id: "shut.secure", phase: .shutdown, title: "Secure aircraft and log hours", required: true),
    ]
}

/// One flight's checklist progress. Only ids from the checklist count, so a tampered run cannot inflate its score.
public struct SOPRun: Codable, Sendable, Equatable {
    public var completed: Set<String> = []

    public init() {}

    public mutating func tick(_ stepID: String, in steps: [SOPStep] = SOPChecklist.standard) {
        guard steps.contains(where: { $0.id == stepID }) else { return }
        completed.insert(stepID)
    }

    /// Required steps still open, in checklist order.
    public func missedRequired(in steps: [SOPStep] = SOPChecklist.standard) -> [SOPStep] {
        steps.filter { $0.required && !completed.contains($0.id) }
    }

    /// 0...1. Required steps are 80% of the score, optional steps 20%.
    public func score(in steps: [SOPStep] = SOPChecklist.standard) -> Double {
        let required = steps.filter { $0.required }
        let optional = steps.filter { !$0.required }
        func fraction(_ list: [SOPStep]) -> Double {
            list.isEmpty ? 1 : Double(list.filter { completed.contains($0.id) }.count) / Double(list.count)
        }
        return 0.8 * fraction(required) + 0.2 * fraction(optional)
    }
}

// MARK: - Routes

/// A scheduled airline leg. Convert with `asJob` to fly it through the job pipeline.
public struct AirlineRoute: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var origin: AirportRef
    public var destination: AirportRef
    public var distanceKm: Double
    /// Scheduled departure, minutes after 00:00 UTC, on a 15-minute grid.
    public var departureMinute: Int
    public var passengers: Int
    public var minimumRank: AirlineRank
    public var expiresDay: Int

    /// Expected block time at the reference cruise speed, plus taxi allowance.
    public var expectedBlockMinutes: Double { AirlineSchedule.blockMinutes(distanceKm: distanceKm) }

    /// Minutes past expected block time that still count as on time.
    public static let onTimeToleranceMinutes = 15.0

    public var basePay: Int {
        Int((Double(passengers) * distanceKm * Economy.passengerRatePerKm * 1.2).rounded())
    }

    public func asJob() -> Job {
        Job(id: id, kind: .passenger, origin: origin, destination: destination, distanceKm: distanceKm,
            passengers: passengers, cargoKg: 0,
            deadlineMinutes: expectedBlockMinutes + Self.onTimeToleranceMinutes,
            basePay: max(100, basePay), minLevel: 1,
            requiresRunwayM: min(destination.longestRunwayM, 400 + distanceKm * 0.4), expiresDay: expiresDay)
    }
}

public enum AirlineRejection: Error, Sendable, Equatable {
    case rankTooLow(needed: AirlineRank)
    case aircraftNotAllowed
    case notEnoughSeats
    case pilotRankTooLow(needed: PilotRank)
}

public enum AirlineSchedule {
    /// Reference cruise speed used for schedule times (kts), matching the job board.
    public static let referenceCruiseKts = 120.0
    public static let taxiAllowanceMinutes = 10.0

    public static func blockMinutes(distanceKm: Double) -> Double {
        guard distanceKm.isFinite, distanceKm > 0 else { return taxiAllowanceMinutes }
        return distanceKm / (referenceCruiseKts * 1.852) * 60 + taxiAllowanceMinutes
    }

    /// Deterministic schedule out of a hub on a UTC day index: same inputs give the same routes on every device.
    /// Sectors are limited to the rank's reach, and passengers to the seats that rank may fly.
    public static func generate(hub: AirportRef, airports: [AirportRef], dayIndex: Int, rank: AirlineRank,
                                count: Int = 6) -> [AirlineRoute] {
        let others = airports.filter { $0.icao != hub.icao }.sorted { $0.icao < $1.icao }
        guard !others.isEmpty, count > 0 else { return [] }
        var rng = Xoshiro256(seed: Hash.mix(UInt64(bitPattern: Int64(dayIndex))) ^ JobBoard.hashString(hub.icao) ^ 0x5CED)
        var routes: [AirlineRoute] = []
        var attempts = 0
        let maxPax = max(1, rank.maxSeats - 1)
        while routes.count < count && attempts < count * 20 {
            attempts += 1
            let dest = others[Int(rng.next() % UInt64(others.count))]
            let distKm = greatCircleDistanceM(hub, dest) / 1000
            guard distKm >= 20, distKm <= rank.maxSectorKm else { continue }
            let pax = 1 + Int(rng.next() % UInt64(maxPax))
            let slot = Int(rng.next() % 96) * 15
            routes.append(AirlineRoute(id: "\(hub.icao)-\(dayIndex)-\(routes.count)", origin: hub, destination: dest,
                                       distanceKm: distKm, departureMinute: slot, passengers: pax,
                                       minimumRank: rank, expiresDay: dayIndex + 1))
        }
        return routes.sorted { $0.departureMinute < $1.departureMinute }
    }

    /// Checks rank, aircraft and seats before a scheduled leg is accepted.
    public static func canAccept(_ route: AirlineRoute, aircraft: HangarAircraft, career: AirlineCareer,
                                 pilotRank: PilotRank) -> AirlineRejection? {
        if career.rank < route.minimumRank { return .rankTooLow(needed: route.minimumRank) }
        if pilotRank < route.minimumRank.minPilotRank { return .pilotRankTooLow(needed: route.minimumRank.minPilotRank) }
        if !career.rank.allows(aircraft) { return .aircraftNotAllowed }
        if aircraft.seats - 1 < route.passengers { return .notEnoughSeats }
        return nil
    }
}

// MARK: - Scoring and settlement

public struct AirlineLegScore: Sendable, Equatable {
    public var completed: Bool
    public var onTime: Bool
    /// Minutes beyond the on-time window (0 when on time or when the leg was not completed).
    public var lateMinutes: Double
    /// Passenger comfort, 0...1.
    public var comfort: Double
    /// Landing quality, 0...1.
    public var landing: Double
    /// Checklist score, 0...1.
    public var sop: Double
    /// Overall leg score, 0...100.
    public var total: Double
}

public struct AirlineSettlement: Sendable, Equatable {
    public var score: AirlineLegScore
    public var reputationDelta: Double
    public var promotedTo: AirlineRank?
}

public enum AirlineEngine {
    /// Scores one scheduled leg. A leg that did not end at the scheduled destination scores zero.
    public static func score(report raw: FlightReport, route: AirlineRoute, sop: SOPRun = SOPRun()) -> AirlineLegScore {
        let r = raw.sanitized()
        let flightMinutes = r.durationS / 60
        let window = route.expectedBlockMinutes + AirlineRoute.onTimeToleranceMinutes
        let flewRoute = r.distanceM >= route.distanceKm * 1000 * 0.6
        let completed = r.landed && !r.crashed && r.arrivalICAO == route.destination.icao
            && r.departureICAO == route.origin.icao && flewRoute
        guard completed else {
            return AirlineLegScore(completed: false, onTime: false, lateMinutes: 0, comfort: 0, landing: 0, sop: 0, total: 0)
        }

        let late = max(0, flightMinutes - window)
        let onTime = late == 0
        let onTimeScore = onTime ? 1.0 : max(0, 1 - late / 60)

        var comfort = 1.0
        if r.maxG >= 1.8 { comfort -= 0.3 }
        if r.minG <= 0.3 { comfort -= 0.2 }
        if r.maxBankDeg >= 30 { comfort -= 0.2 }
        comfort = max(0, comfort)

        var landing: Double
        switch r.touchdownSinkFPM {
        case .some(let s) where s < 120: landing = 1
        case .some(let s) where s < 250: landing = 0.7
        case .some(let s) where s < 400: landing = 0.3
        default: landing = 0
        }
        if let off = r.touchdownOffsetM, abs(off) > 15 { landing *= 0.8 }

        let sopScore = min(max(sop.score(), 0), 1)
        let total = 100 * (0.5 * onTimeScore + 0.25 * comfort + 0.15 * landing + 0.10 * sopScore)
        return AirlineLegScore(completed: true, onTime: onTime, lateMinutes: late, comfort: comfort,
                               landing: landing, sop: sopScore, total: min(max(total, 0), 100))
    }

    /// Scores a leg and updates the airline record: reputation, legs, best score and rank. Pay itself stays with
    /// the job settlement in `CareerEngine`, so money is never counted twice.
    @discardableResult
    public static func settle(report: FlightReport, route: AirlineRoute, sop: SOPRun = SOPRun(),
                              career: inout AirlineCareer) -> AirlineSettlement {
        let s = score(report: report, route: route, sop: sop)
        let delta: Double
        if s.completed {
            delta = (s.total - 60) / 10          // -6 at a score of 0, +4 at 100
            career.legsFlown += 1
            if s.onTime { career.legsOnTime += 1 }
            career.bestLegScore = max(career.bestLegScore, s.total)
        } else {
            delta = report.crashed ? -10 : -5
        }
        career.reputation = min(max(career.reputation + delta, 0), 100)

        var promoted: AirlineRank? = nil
        if let next = career.rank.next, career.legsFlown >= next.legsRequired, career.reputation >= next.reputationRequired {
            career.rank = next
            promoted = next
        }
        career.sanitize()
        return AirlineSettlement(score: s, reputationDelta: delta, promotedTo: promoted)
    }
}
