// SKYFORGE — Apache-2.0
// Scoring for landing challenges, time trials and aerobatics, plus deterministic daily challenges.
import Foundation
import SFMath

public enum Medal: Int, Codable, Sendable, Comparable, CaseIterable {
    case none, bronze, silver, gold, platinum
    public static func < (a: Medal, b: Medal) -> Bool { a.rawValue < b.rawValue }
    public var xp: Int { [0, 60, 120, 220, 400][rawValue] }
    public var credits: Int { [0, 200, 450, 900, 2_000][rawValue] }
    public static func forScore(_ score: Double, thresholds t: [Double]) -> Medal {
        // t = [bronze, silver, gold, platinum]
        guard t.count == 4 else { return .none }
        if score >= t[3] { return .platinum }
        if score >= t[2] { return .gold }
        if score >= t[1] { return .silver }
        if score >= t[0] { return .bronze }
        return .none
    }
}

public enum AerobaticFigure: String, Codable, Sendable, CaseIterable {
    case loop, aileronRoll, barrelRoll, immelmann, splitS, hammerhead, cuban8, knifeEdge, inverted, spin
    /// Difficulty coefficient K, in the style of competition aerobatics catalogues.
    public var k: Double {
        switch self {
        case .loop: return 4
        case .aileronRoll: return 3
        case .barrelRoll: return 4
        case .immelmann: return 5
        case .splitS: return 5
        case .hammerhead: return 6
        case .cuban8: return 7
        case .knifeEdge: return 6
        case .inverted: return 3
        case .spin: return 5
        }
    }
}

public enum ChallengeScoring {
    /// Landing score 0...1000 from touchdown quality. Crash/no-landing = 0.
    public static func landing(_ r: FlightReport) -> Double {
        let r = r.sanitized()
        guard r.landed, !r.crashed, let sink = r.touchdownSinkFPM else { return 0 }
        let sinkScore = 400 * smoothFalloff(max(0, sink), good: 120, bad: 600)
        let off = abs(r.touchdownOffsetM ?? 50)
        let centreScore = 300 * smoothFalloff(off, good: 1.5, bad: 15)
        // Ideal touchdown zone: 150...450 m past threshold.
        let d = r.touchdownDistancePastThresholdM ?? 2_000
        let zoneErr = d < 150 ? 150 - d : max(0, d - 450)
        let zoneScore = 300 * smoothFalloff(zoneErr, good: 20, bad: 900)
        return (sinkScore + centreScore + zoneScore).rounded()
    }

    /// 1 when value <= good, 0 when value >= bad, smooth in between.
    static func smoothFalloff(_ v: Double, good: Double, bad: Double) -> Double {
        if v <= good { return 1 }
        if v >= bad { return 0 }
        let t = (v - good) / (bad - good)
        return 1 - t * t * (3 - 2 * t)
    }

    /// Time trial score: gates are mandatory (each missed gate costs a 10 s penalty), score is par/time scaled to 1000.
    public static func timeTrial(_ r: FlightReport, parSeconds: Double) -> Double {
        let r = r.sanitized()
        guard !r.crashed, r.gatesTotal > 0, r.gatesPassed * 5 >= r.gatesTotal * 4, let t = r.completionTimeS, t > 0, parSeconds > 0 else { return 0 }
        let missed = r.gatesTotal - r.gatesPassed
        let effective = t + Double(missed) * 10
        return min(1_500, (1_000 * parSeconds / effective)).rounded()
    }

    /// Aerobatic score: sum of K × quality, repeats of the same figure decay (0.6 each), g-over-stress and crash void it.
    public static func aerobatics(_ r: FlightReport) -> Double {
        let r = r.sanitized()
        guard !r.crashed else { return 0 }
        var seen: [AerobaticFigure: Int] = [:]
        var total = 0.0
        for fig in r.aerobaticFigures {
            let n = seen[fig, default: 0]
            seen[fig] = n + 1
            total += fig.k * 10 * pow(0.6, Double(n))
        }
        let overG = max(0, r.maxG - 9)
        return max(0, (total * (1 - min(0.5, overG * 0.1)))).rounded()
    }

    /// Combat score: kills dominate, survival and mission success add on top.
    public static func combat(_ r: FlightReport) -> Double {
        let r = r.sanitized()
        var s = Double(r.kills) * 300
        if r.missionSuccess { s += 500 }
        if !r.crashed && r.deaths == 0 { s += 200 }
        s -= Double(r.deaths) * 250
        return max(0, s)
    }
}

public enum ChallengeType: String, Codable, Sendable, CaseIterable {
    case landing, timeTrial, aerobatics, combat
}

public struct Challenge: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: ChallengeType
    public var title: String
    public var airportICAO: String
    public var parSeconds: Double
    public var medalThresholds: [Double]
    public var crosswindKts: Double
    public var visibilityKm: Double
    public var cloudBaseFt: Double
    public var aircraftID: String

    public func score(_ r: FlightReport) -> Double {
        switch type {
        case .landing: return ChallengeScoring.landing(r)
        case .timeTrial: return ChallengeScoring.timeTrial(r, parSeconds: parSeconds)
        case .aerobatics: return ChallengeScoring.aerobatics(r)
        case .combat: return ChallengeScoring.combat(r)
        }
    }
    public func medal(for r: FlightReport) -> Medal { Medal.forScore(score(r), thresholds: medalThresholds) }
}

public enum DailyChallenge {
    public static func dayIndex(epochSeconds: Int) -> Int { Int((Double(max(0, epochSeconds)) / 86_400).rounded(.down)) }

    /// One challenge per UTC day, identical for everyone: same seed → same weather/airport/type.
    public static func make(dayIndex: Int, airports: [AirportRef], aircraftIDs: [String]) -> Challenge? {
        guard !airports.isEmpty, !aircraftIDs.isEmpty else { return nil }
        var rng = Xoshiro256(seed: Hash.mix(UInt64(bitPattern: Int64(dayIndex))) ^ 0xDA11_C4A1)
        let type = ChallengeType.allCases[Int(rng.next() % UInt64(ChallengeType.allCases.count))]
        let ap = airports[Int(rng.next() % UInt64(airports.count))]
        let ac = aircraftIDs[Int(rng.next() % UInt64(aircraftIDs.count))]
        let xw = (rng.range(0, 18)).rounded()
        let vis = (rng.range(2, 15)).rounded()
        let cloud = (rng.range(800, 5_000) / 100).rounded() * 100
        let par = (90 + rng.range(0, 150)).rounded()
        let thr: [Double]
        let title: String
        switch type {
        case .landing: thr = [500, 700, 850, 950]; title = "Daily landing at \(ap.icao): \(Int(xw)) kt crosswind"
        case .timeTrial: thr = [600, 800, 950, 1_100]; title = "Daily gate run near \(ap.icao)"
        case .aerobatics: thr = [60, 120, 200, 300]; title = "Daily aerobatic routine over \(ap.icao)"
        case .combat: thr = [300, 600, 1_000, 1_500]; title = "Daily sortie from \(ap.icao)"
        }
        return Challenge(id: "daily-\(dayIndex)", type: type, title: title, airportICAO: ap.icao, parSeconds: par,
                         medalThresholds: thr, crosswindKts: xw, visibilityKm: vis, cloudBaseFt: cloud, aircraftID: ac)
    }
}
