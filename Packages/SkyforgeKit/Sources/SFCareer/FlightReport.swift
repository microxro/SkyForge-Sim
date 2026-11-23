// SKYFORGE — Apache-2.0
// The single input the career layer consumes. The sim / gameplay layer fills one in per flight.
import Foundation

public enum FlightKind: Codable, Sendable, Equatable {
    case freeFlight
    case job(jobID: String)
    case challenge(challengeID: String)
    case mission(missionID: String)
}

public struct FlightReport: Codable, Sendable, Equatable {
    public var kind: FlightKind
    public var aircraftID: String
    public var departureICAO: String
    /// ICAO of the airport the aircraft came to rest at on a runway, nil if it did not land at one.
    public var arrivalICAO: String?
    public var durationS: Double
    public var distanceM: Double
    public var landed: Bool
    public var crashed: Bool
    /// Touchdown sink rate in feet per minute, positive = descending (a typical good landing is 100-250).
    public var touchdownSinkFPM: Double?
    /// Lateral offset from runway centreline at touchdown (m).
    public var touchdownOffsetM: Double?
    /// Distance past the threshold at touchdown (m).
    public var touchdownDistancePastThresholdM: Double?
    public var maxG: Double
    public var minG: Double
    public var maxBankDeg: Double
    public var fuelUsedKg: Double
    public var kills: Int
    public var deaths: Int
    public var missionSuccess: Bool
    /// Raw score from the mission/challenge itself (already computed by the gameplay layer), if any.
    public var rawScore: Double?
    public var aerobaticFigures: [AerobaticFigure]
    public var gatesPassed: Int
    public var gatesTotal: Int
    /// Wall-clock simulation seconds the player spent on this flight (for time trials).
    public var completionTimeS: Double?
    /// Unix seconds when the flight ended (UTC).
    public var endedAt: Int

    public init(kind: FlightKind = .freeFlight, aircraftID: String, departureICAO: String = "", arrivalICAO: String? = nil,
                durationS: Double = 0, distanceM: Double = 0, landed: Bool = false, crashed: Bool = false,
                touchdownSinkFPM: Double? = nil, touchdownOffsetM: Double? = nil, touchdownDistancePastThresholdM: Double? = nil,
                maxG: Double = 1, minG: Double = 1, maxBankDeg: Double = 0, fuelUsedKg: Double = 0,
                kills: Int = 0, deaths: Int = 0, missionSuccess: Bool = false, rawScore: Double? = nil,
                aerobaticFigures: [AerobaticFigure] = [], gatesPassed: Int = 0, gatesTotal: Int = 0,
                completionTimeS: Double? = nil, endedAt: Int = 0) {
        self.kind = kind; self.aircraftID = aircraftID; self.departureICAO = departureICAO; self.arrivalICAO = arrivalICAO
        self.durationS = durationS; self.distanceM = distanceM; self.landed = landed; self.crashed = crashed
        self.touchdownSinkFPM = touchdownSinkFPM; self.touchdownOffsetM = touchdownOffsetM
        self.touchdownDistancePastThresholdM = touchdownDistancePastThresholdM
        self.maxG = maxG; self.minG = minG; self.maxBankDeg = maxBankDeg; self.fuelUsedKg = fuelUsedKg
        self.kills = kills; self.deaths = deaths; self.missionSuccess = missionSuccess; self.rawScore = rawScore
        self.aerobaticFigures = aerobaticFigures; self.gatesPassed = gatesPassed; self.gatesTotal = gatesTotal
        self.completionTimeS = completionTimeS; self.endedAt = endedAt
    }

    /// Returns a copy with every number made finite and clamped to a physically plausible range, so one
    /// bad frame (NaN, inf) or a tampered report can never corrupt the save file or overflow the economy.
    public func sanitized() -> FlightReport {
        var r = self
        func f(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double = 0) -> Double {
            v.isFinite ? min(hi, max(lo, v)) : fallback
        }
        func fo(_ v: Double?, _ lo: Double, _ hi: Double) -> Double? { v.map { f($0, lo, hi) } }
        r.durationS = f(durationS, 0, 86_400)
        r.distanceM = f(distanceM, 0, 2.0e7)
        r.touchdownSinkFPM = fo(touchdownSinkFPM, 0, 20_000)
        r.touchdownOffsetM = fo(touchdownOffsetM, -5_000, 5_000)
        r.touchdownDistancePastThresholdM = fo(touchdownDistancePastThresholdM, -5_000, 20_000)
        r.maxG = f(maxG, -20, 30, 1)
        r.minG = f(minG, -20, 30, 1)
        r.maxBankDeg = f(maxBankDeg, 0, 360)
        r.fuelUsedKg = f(fuelUsedKg, 0, 500_000)
        r.kills = min(max(kills, 0), 200)
        r.deaths = min(max(deaths, 0), 50)
        r.rawScore = fo(rawScore, 0, 1.0e7)
        r.gatesTotal = min(max(gatesTotal, 0), 500)
        r.gatesPassed = min(max(gatesPassed, 0), r.gatesTotal)
        r.completionTimeS = fo(completionTimeS, 0, 86_400)
        r.aerobaticFigures = Array(aerobaticFigures.prefix(200))
        r.endedAt = max(0, endedAt)
        if r.crashed { r.landed = false }
        return r
    }
}
