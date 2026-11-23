// SKYFORGE — Apache-2.0
// Airports, aircraft economics and the job board. Everything here is data + pure functions.
import Foundation
import SFMath

public struct AirportRef: Codable, Sendable, Equatable, Hashable {
    public var icao: String
    public var name: String
    public var latitudeDeg: Double
    public var longitudeDeg: Double
    public var longestRunwayM: Double
    public init(icao: String, name: String, latitudeDeg: Double, longitudeDeg: Double, longestRunwayM: Double) {
        self.icao = icao; self.name = name; self.latitudeDeg = latitudeDeg; self.longitudeDeg = longitudeDeg
        self.longestRunwayM = longestRunwayM
    }
}

public func greatCircleDistanceM(_ a: AirportRef, _ b: AirportRef) -> Double {
    let p = Geodetic(latitude: a.latitudeDeg * .pi / 180, longitude: a.longitudeDeg * .pi / 180, height: 0)
    let q = Geodetic(latitude: b.latitudeDeg * .pi / 180, longitude: b.longitudeDeg * .pi / 180, height: 0)
    return Geodesic.inverse(p, q).distance
}

/// Economic description of an aircraft. Ids are strings so this module never depends on SFFlightModel / SFGameplay.
public struct HangarAircraft: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var seats: Int
    public var payloadKg: Double
    public var rangeKm: Double
    public var cruiseKts: Double
    public var minRunwayM: Double
    public var purchasePrice: Int
    public var rentalPerHour: Int
    public var fuelBurnKgPerHour: Double
    public var unlockLevel: Int
    public var isMilitary: Bool
    public init(id: String, name: String, seats: Int, payloadKg: Double, rangeKm: Double, cruiseKts: Double, minRunwayM: Double,
                purchasePrice: Int, rentalPerHour: Int, fuelBurnKgPerHour: Double, unlockLevel: Int, isMilitary: Bool = false) {
        self.id = id; self.name = name; self.seats = seats; self.payloadKg = payloadKg; self.rangeKm = rangeKm
        self.cruiseKts = cruiseKts; self.minRunwayM = minRunwayM; self.purchasePrice = purchasePrice
        self.rentalPerHour = rentalPerHour; self.fuelBurnKgPerHour = fuelBurnKgPerHour
        self.unlockLevel = unlockLevel; self.isMilitary = isMilitary
    }
}

public enum Economy {
    public static let startingCredits = 5_000
    public static let fuelPricePerKg = 1.6
    /// Credits per kilometre per passenger / per 100 kg cargo.
    public static let passengerRatePerKm = 0.9
    public static let cargoRatePer100KgKm = 0.35

    /// Hangar catalog. Every id here must be flyable on main (SFFlightModel/AircraftCatalog or SFGameplay/Aircraft).
    /// Retired ids (sf2, sf5, sf9 had no gameplay aircraft spec) are refunded on load, see `retiredAircraftRefunds`.
    public static let catalog: [HangarAircraft] = [
        .init(id: "org.skyforge.sf1", name: "SF-1 Trainer", seats: 1, payloadKg: 150, rangeKm: 600, cruiseKts: 105, minRunwayM: 450, purchasePrice: 0, rentalPerHour: 0, fuelBurnKgPerHour: 28, unlockLevel: 1),
        .init(id: "org.skyforge.sfc", name: "SF-C Cruiser", seats: 3, payloadKg: 320, rangeKm: 1_100, cruiseKts: 130, minRunwayM: 600, purchasePrice: 45_000, rentalPerHour: 90, fuelBurnKgPerHour: 38, unlockLevel: 3),
        .init(id: "org.skyforge.sfa", name: "SF-A Aerobat", seats: 1, payloadKg: 110, rangeKm: 500, cruiseKts: 140, minRunwayM: 400, purchasePrice: 38_000, rentalPerHour: 110, fuelBurnKgPerHour: 42, unlockLevel: 5),
        .init(id: "org.skyforge.sf3", name: "SF-3 Twin", seats: 6, payloadKg: 780, rangeKm: 2_200, cruiseKts: 200, minRunwayM: 900, purchasePrice: 340_000, rentalPerHour: 420, fuelBurnKgPerHour: 120, unlockLevel: 14),
        .init(id: "org.skyforge.sft1", name: "SF-T1 Jet Trainer", seats: 2, payloadKg: 200, rangeKm: 1_500, cruiseKts: 340, minRunwayM: 1_200, purchasePrice: 900_000, rentalPerHour: 800, fuelBurnKgPerHour: 380, unlockLevel: 20, isMilitary: true),
        .init(id: "org.skyforge.sff1", name: "SF-F1 Interceptor", seats: 1, payloadKg: 300, rangeKm: 1_900, cruiseKts: 480, minRunwayM: 1_500, purchasePrice: 3_500_000, rentalPerHour: 2_400, fuelBurnKgPerHour: 1_200, unlockLevel: 36, isMilitary: true),
    ]

    /// Aircraft that were once sold but cannot be flown. Owners get the purchase price back on load.
    public static let retiredAircraftRefunds: [String: Int] = [
        "org.skyforge.sf2": 120_000, "org.skyforge.sf5": 1_200_000, "org.skyforge.sf9": 8_000_000,
    ]

    public static func spec(_ id: String, in catalog: [HangarAircraft] = Economy.catalog) -> HangarAircraft? {
        catalog.first { $0.id == id }
    }

    public static func levelUpCreditBonus(_ level: Int) -> Int { 500 + 150 * max(0, level - 1) }
}

public enum JobKind: String, Codable, Sendable, CaseIterable {
    case passenger, cargo, ferry, medevac, survey
}

public struct Job: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: JobKind
    public var origin: AirportRef
    public var destination: AirportRef
    public var distanceKm: Double
    public var passengers: Int
    public var cargoKg: Double
    /// Allowed time in minutes before the late penalty starts.
    public var deadlineMinutes: Double
    public var basePay: Int
    public var minLevel: Int
    public var requiresRunwayM: Double
    public var expiresDay: Int
}

public enum JobBoard {
    /// Deterministic job board for an origin on a given UTC day index (epoch/86400). Same inputs → same board on every device,
    /// so players can compare notes and tests are exact.
    public static func generate(origin: AirportRef, airports: [AirportRef], dayIndex: Int, playerLevel: Int, count: Int = 8) -> [Job] {
        let others = airports.filter { $0.icao != origin.icao }.sorted { $0.icao < $1.icao }
        guard !others.isEmpty, count > 0 else { return [] }
        var rng = Xoshiro256(seed: Hash.mix(UInt64(bitPattern: Int64(dayIndex))) ^ hashString(origin.icao))
        var jobs: [Job] = []
        for i in 0..<count {
            let dest = others[Int(rng.next() % UInt64(others.count))]
            let distKm = max(1, greatCircleDistanceM(origin, dest) / 1000)
            let kind = JobKind.allCases[Int(rng.next() % UInt64(JobKind.allCases.count))]
            var pax = 0, cargo = 0.0
            var pay = 0.0
            var minLevel = 1
            switch kind {
            case .passenger:
                pax = 1 + Int(rng.next() % 5)
                pay = Double(pax) * distKm * Economy.passengerRatePerKm
            case .cargo:
                cargo = (50 + rng.range(0, 700)).rounded()
                pay = cargo / 100 * distKm * Economy.cargoRatePer100KgKm
            case .ferry:
                pay = distKm * 1.4; minLevel = 4
            case .medevac:
                pax = 1; pay = distKm * 2.8 + 400; minLevel = 6
            case .survey:
                pay = distKm * 1.1 + 250; minLevel = 3
            }
            let cruiseKts = 120.0
            let flightMin = distKm * 1000 / (cruiseKts * 0.5144) / 60
            let urgency = kind == .medevac ? 1.15 : 1.5
            let deadline = max(10, flightMin * urgency + 8)
            let level = max(minLevel, min(playerLevel + 3, 1 + Int(distKm / 120)))
            jobs.append(Job(id: "\(origin.icao)-\(dayIndex)-\(i)", kind: kind, origin: origin, destination: dest,
                            distanceKm: distKm, passengers: pax, cargoKg: cargo, deadlineMinutes: deadline,
                            basePay: max(100, Int(pay.rounded())), minLevel: level,
                            requiresRunwayM: min(dest.longestRunwayM, 400 + distKm * 0.4), expiresDay: dayIndex + 2))
        }
        return jobs.sorted { $0.distanceKm < $1.distanceKm }
    }

    public static func canFly(_ job: Job, with a: HangarAircraft, level: Int) -> Result<Void, JobRejection> {
        if level < job.minLevel { return .failure(.levelTooLow(needed: job.minLevel)) }
        if a.seats - 1 < job.passengers && job.passengers > 0 { return .failure(.notEnoughSeats) }
        if a.payloadKg < job.cargoKg + Double(job.passengers) * 80 { return .failure(.overweight) }
        if a.rangeKm < job.distanceKm * 1.15 { return .failure(.outOfRange) }
        if a.minRunwayM > job.destination.longestRunwayM || a.minRunwayM > job.origin.longestRunwayM { return .failure(.runwayTooShort) }
        return .success(())
    }

    static func hashString(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}

public enum JobRejection: Error, Sendable, Equatable {
    case alreadyHaveJob, levelTooLow(needed: Int), notEnoughSeats, overweight, outOfRange, runwayTooShort
}

/// Result of settling a job after the flight.
public struct JobSettlement: Codable, Sendable, Equatable {
    public var success: Bool
    public var payout: Int
    public var onTimeBonus: Int
    public var smoothBonus: Int
    public var latePenalty: Int
    public var damagePenalty: Int
    public var fuelCost: Int
    public var net: Int { payout + onTimeBonus + smoothBonus - latePenalty - damagePenalty - fuelCost }
}

public enum JobSettler {
    public static func settle(job: Job, report r: FlightReport, owned: Bool, rentalPerHour: Int = 0) -> JobSettlement {
        let rr = r.sanitized()
        let fuel = owned ? Int((rr.fuelUsedKg * Economy.fuelPricePerKg).rounded()) : Int((Double(rentalPerHour) * rr.durationS / 3600).rounded())
        let flewFar = rr.distanceM >= job.distanceKm * 1000 * 0.6
        let atDest = rr.landed && !rr.crashed && rr.arrivalICAO == job.destination.icao && rr.departureICAO == job.origin.icao && flewFar
        guard atDest else {
            let penalty = rr.crashed ? job.basePay / 2 : 0
            return JobSettlement(success: false, payout: 0, onTimeBonus: 0, smoothBonus: 0, latePenalty: 0, damagePenalty: penalty, fuelCost: fuel)
        }
        let minutes = rr.durationS / 60
        let onTime = minutes <= job.deadlineMinutes
        let lateFrac = onTime ? 0 : min(0.6, (minutes - job.deadlineMinutes) / job.deadlineMinutes)
        let comfortOK = rr.maxG < 1.8 && rr.minG > 0.3 && rr.maxBankDeg < 40
        let gentleLanding = (rr.touchdownSinkFPM ?? 9_999) < 250
        let passengerPenaltyFrac = (job.passengers > 0 && !comfortOK) ? 0.2 : 0
        let base = Double(job.basePay)
        return JobSettlement(
            success: true,
            payout: Int(base.rounded()),
            onTimeBonus: onTime ? Int((base * 0.15).rounded()) : 0,
            smoothBonus: gentleLanding ? Int((base * 0.10).rounded()) : 0,
            latePenalty: Int((base * (lateFrac + passengerPenaltyFrac)).rounded()),
            damagePenalty: 0,
            fuelCost: fuel)
    }
}
