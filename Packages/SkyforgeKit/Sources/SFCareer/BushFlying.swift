// SKYFORGE — Apache-2.0
// Bush flying: remote strips, cargo and passenger hauls to them, weather risk and exploration discoveries.
// Everything here is data plus pure functions, so the rules are tested on Linux. It reuses the career's aircraft
// economics (HangarAircraft), the job settlement shape (JobSettlement) and the deterministic board pattern (JobBoard).
import Foundation
import SFMath

/// Ground surface of a strip. Unpaved surfaces need more ground roll and an aircraft that is rated for them.
public enum StripSurface: String, Codable, Sendable, CaseIterable {
    case paved, gravel, grass, mud

    public var isUnpaved: Bool { self != .paved }

    /// Multiplier on an aircraft's paved minimum runway length. A strip must be this much longer to be usable.
    public var runwayFactor: Double {
        switch self {
        case .paved: return 1.0
        case .gravel: return 1.15
        case .grass: return 1.25
        case .mud: return 1.40
        }
    }

    public var displayName: String {
        switch self {
        case .paved: return "Paved"
        case .gravel: return "Gravel"
        case .grass: return "Grass"
        case .mud: return "Mud"
        }
    }
}

/// A remote strip. Coordinates and names are fictional and only used for distances in the game world.
public struct BushStrip: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// Short id (at most 8 characters, like an ICAO code) so it can key the logbook and flight reports.
    public var id: String
    public var name: String
    public var latitudeDeg: Double
    public var longitudeDeg: Double
    public var lengthM: Double
    public var surface: StripSurface
    public var elevationFt: Double
    /// 0 = next to a town, 1 = nothing for hundreds of kilometres.
    public var remoteness: Double

    public init(id: String, name: String, latitudeDeg: Double, longitudeDeg: Double, lengthM: Double,
                surface: StripSurface, elevationFt: Double, remoteness: Double) {
        self.id = id; self.name = name; self.latitudeDeg = latitudeDeg; self.longitudeDeg = longitudeDeg
        self.lengthM = lengthM; self.surface = surface; self.elevationFt = elevationFt; self.remoteness = remoteness
    }

    /// The strip seen as an airport, so great-circle distance and the logbook work unchanged.
    public var airportRef: AirportRef {
        AirportRef(icao: id, name: name, latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg, longestRunwayM: lengthM)
    }
}

public enum BushStripCatalog {
    /// The hub where every contract is picked up. It is a paved strip, so every aircraft can reach it.
    public static let hub = BushStrip(id: "BSHHUB", name: "Tanana Hub", latitudeDeg: 59.65, longitudeDeg: -135.07,
                                      lengthM: 1_600, surface: .paved, elevationFt: 500, remoteness: 0.1)

    public static let strips: [BushStrip] = [
        BushStrip(id: "BSH01", name: "Caribou Bar", latitudeDeg: 59.10, longitudeDeg: -135.20, lengthM: 620, surface: .gravel, elevationFt: 1_400, remoteness: 0.35),
        BushStrip(id: "BSH02", name: "Moose Creek", latitudeDeg: 60.45, longitudeDeg: -137.80, lengthM: 480, surface: .grass, elevationFt: 900, remoteness: 0.55),
        BushStrip(id: "BSH03", name: "Hollow Lake", latitudeDeg: 61.05, longitudeDeg: -139.90, lengthM: 750, surface: .mud, elevationFt: 1_200, remoteness: 0.75),
        BushStrip(id: "BSH04", name: "Spruce Bend", latitudeDeg: 58.70, longitudeDeg: -133.50, lengthM: 900, surface: .gravel, elevationFt: 300, remoteness: 0.20),
        BushStrip(id: "BSH05", name: "Fox Ridge", latitudeDeg: 62.30, longitudeDeg: -141.10, lengthM: 390, surface: .grass, elevationFt: 2_100, remoteness: 0.85),
        BushStrip(id: "BSH06", name: "Owl Pass", latitudeDeg: 60.90, longitudeDeg: -136.40, lengthM: 1_100, surface: .paved, elevationFt: 1_700, remoteness: 0.60),
        BushStrip(id: "BSH07", name: "Trapper Flats", latitudeDeg: 59.85, longitudeDeg: -138.60, lengthM: 540, surface: .mud, elevationFt: 700, remoteness: 0.70),
        BushStrip(id: "BSH08", name: "Glacier Shelf", latitudeDeg: 61.70, longitudeDeg: -140.40, lengthM: 330, surface: .gravel, elevationFt: 3_400, remoteness: 0.95),
    ]

    public static func strip(id: String) -> BushStrip? {
        id == hub.id ? hub : strips.first { $0.id == id }
    }

    /// Aircraft rated to operate from unpaved strips. Everything else is paved-only.
    public static let unpavedCapableAircraft: Set<String> = [
        "org.skyforge.sf1", "org.skyforge.sfc", "org.skyforge.sf3",
    ]
}

public enum BushContractKind: String, Codable, Sendable, CaseIterable {
    case cargo, passenger
}

/// A hop from the hub to a remote strip (or back). Picked up and flown like a job, with bush-specific rules.
public struct BushContract: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: BushContractKind
    public var origin: BushStrip
    public var destination: BushStrip
    public var distanceKm: Double
    public var passengers: Int
    public var cargoKg: Double
    /// Minutes before the late penalty starts.
    public var deadlineMinutes: Double
    /// Pay before penalties and bonuses. Already includes the weather risk premium.
    public var basePay: Int
    /// 0...1. Chance-style risk of a rough ride on this route. Higher means a bigger premium and a bigger penalty if it hits.
    public var weatherRisk: Double
    public var minLevel: Int
    public var expiresDay: Int

    public init(id: String, kind: BushContractKind, origin: BushStrip, destination: BushStrip, distanceKm: Double,
                passengers: Int, cargoKg: Double, deadlineMinutes: Double, basePay: Int, weatherRisk: Double,
                minLevel: Int, expiresDay: Int) {
        self.id = id; self.kind = kind; self.origin = origin; self.destination = destination; self.distanceKm = distanceKm
        self.passengers = passengers; self.cargoKg = cargoKg; self.deadlineMinutes = deadlineMinutes; self.basePay = basePay
        self.weatherRisk = weatherRisk; self.minLevel = minLevel; self.expiresDay = expiresDay
    }
}

public enum BushRejection: Error, Sendable, Equatable {
    case alreadyHaveContract, levelTooLow(needed: Int), notEnoughSeats, overweight, outOfRange
    case stripTooShort, unpavedNotRated
}

public enum BushBoard {
    /// Deterministic bush board for a day index, so every device shows the same contracts.
    /// Each contract is hub to strip or strip to hub, so the aircraft always comes back.
    public static func generate(hub: BushStrip = BushStripCatalog.hub, strips: [BushStrip] = BushStripCatalog.strips,
                                dayIndex: Int, playerLevel: Int, count: Int = 6) -> [BushContract] {
        guard !strips.isEmpty, count > 0 else { return [] }
        let ordered = strips.sorted { $0.id < $1.id }
        var rng = Xoshiro256(seed: Hash.mix(UInt64(bitPattern: Int64(dayIndex))) ^ JobBoard.hashString("bush-" + hub.id))
        var out: [BushContract] = []
        for i in 0..<count {
            let strip = ordered[Int(rng.next() % UInt64(ordered.count))]
            let outbound = rng.next() % 2 == 0
            let origin = outbound ? hub : strip
            let destination = outbound ? strip : hub
            let distKm = max(1, greatCircleDistanceM(origin.airportRef, destination.airportRef) / 1000)
            let kind: BushContractKind = rng.next() % 2 == 0 ? .cargo : .passenger
            var pax = 0
            var cargo = 0.0
            var pay: Double
            if kind == .cargo {
                cargo = (60 + rng.range(0, 500)).rounded()
                pay = cargo / 100 * distKm * Economy.cargoRatePer100KgKm * 2.2
            } else {
                pax = 1 + Int(rng.next() % 3)
                pay = Double(pax) * distKm * Economy.passengerRatePerKm * 1.6
            }
            // Remote strips pay a premium, and that premium rises with weather risk.
            let risk = min(1, max(0, strip.remoteness * 0.7 + rng.range(0, 0.3)))
            pay *= 1 + 0.5 * risk
            let flightMin = distKm * 1000 / (120 * 0.5144) / 60
            let deadline = max(15, flightMin * 1.6 + 10)
            let minLevel = max(1, min(playerLevel + 3, 1 + Int(strip.remoteness * 8)))
            out.append(BushContract(id: "bush-\(dayIndex)-\(i)", kind: kind, origin: origin, destination: destination,
                                    distanceKm: distKm, passengers: pax, cargoKg: cargo, deadlineMinutes: deadline,
                                    basePay: max(150, Int(pay.rounded())), weatherRisk: risk, minLevel: minLevel,
                                    expiresDay: dayIndex + 2))
        }
        return out.sorted { $0.distanceKm < $1.distanceKm }
    }
}

public enum BushRules {
    /// Can this aircraft fly this contract now? Checks level, seats, payload, range, strip length and surface rating.
    public static func canFly(_ c: BushContract, with a: HangarAircraft, level: Int) -> Result<Void, BushRejection> {
        if level < c.minLevel { return .failure(.levelTooLow(needed: c.minLevel)) }
        if c.passengers > 0 && a.seats - 1 < c.passengers { return .failure(.notEnoughSeats) }
        if a.payloadKg < c.cargoKg + Double(c.passengers) * 80 { return .failure(.overweight) }
        if a.rangeKm < c.distanceKm * 1.15 { return .failure(.outOfRange) }
        for strip in [c.origin, c.destination] {
            if strip.surface.isUnpaved && !BushStripCatalog.unpavedCapableAircraft.contains(a.id) { return .failure(.unpavedNotRated) }
            if strip.lengthM < a.minRunwayM * strip.surface.runwayFactor { return .failure(.stripTooShort) }
        }
        return .success(())
    }
}

/// One thing the pilot discovered on a flight. Each discovery is paid once, ever.
public struct BushDiscovery: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var xp: Int
    public var credits: Int
}

public enum BushExploration {
    /// Discoveries from a landed flight, skipping any already in `known`. Pure: the caller stores the ids.
    /// Touchdown within the first 30% of the strip counts as a short-field landing.
    public static func discoveries(for raw: FlightReport, known: Set<String>) -> [BushDiscovery] {
        let r = raw.sanitized()
        guard r.landed, !r.crashed, let icao = r.arrivalICAO, let strip = BushStripCatalog.strip(id: icao) else { return [] }
        var out: [BushDiscovery] = []
        func add(_ key: String, _ title: String, xp: Int, credits: Int) {
            if !known.contains(key) { out.append(BushDiscovery(id: key, title: title, xp: xp, credits: credits)) }
        }
        add("landing:\(strip.id)", "First landing at \(strip.name)",
            xp: 40 + Int(strip.remoteness * 160), credits: 150 + Int(strip.remoteness * 400))
        if strip.surface.isUnpaved {
            add("unpaved", "First unpaved landing", xp: 80, credits: 300)
        }
        if strip.remoteness >= 0.8 {
            add("deep-bush", "Deep bush landing", xp: 150, credits: 600)
        }
        if let past = r.touchdownDistancePastThresholdM, past >= 0, past <= strip.lengthM * 0.3 {
            add("short-field", "Short-field touchdown", xp: 100, credits: 400)
        }
        return out
    }
}

public enum BushSettler {
    /// Settles a bush contract. Mirrors JobSettler, plus a weather rule: a rough ride on a risky route costs a share of pay.
    public static func settle(contract c: BushContract, report raw: FlightReport, owned: Bool, rentalPerHour: Int = 0) -> JobSettlement {
        let r = raw.sanitized()
        let fuel = owned ? Int((r.fuelUsedKg * Economy.fuelPricePerKg).rounded()) : Int((Double(rentalPerHour) * r.durationS / 3600).rounded())
        let flewFar = r.distanceM >= c.distanceKm * 1000 * 0.6
        let atDest = r.landed && !r.crashed && r.arrivalICAO == c.destination.id && r.departureICAO == c.origin.id && flewFar
        guard atDest else {
            let penalty = r.crashed ? c.basePay / 2 : 0
            return JobSettlement(success: false, payout: 0, onTimeBonus: 0, smoothBonus: 0, latePenalty: 0, damagePenalty: penalty, fuelCost: fuel)
        }
        let minutes = r.durationS / 60
        let onTime = minutes <= c.deadlineMinutes
        let lateFrac = onTime ? 0 : min(0.6, (minutes - c.deadlineMinutes) / c.deadlineMinutes)
        let base = Double(c.basePay)
        let upset = r.maxG >= 1.8 || r.minG <= 0.3
        let rough = upset ? base * 0.2 * c.weatherRisk : 0
        let comfortFrac = (c.passengers > 0 && (upset || r.maxBankDeg >= 40)) ? 0.2 : 0
        let gentleLanding = (r.touchdownSinkFPM ?? 9_999) < 250
        return JobSettlement(
            success: true,
            payout: Int(base.rounded()),
            onTimeBonus: onTime ? Int((base * 0.15).rounded()) : 0,
            smoothBonus: gentleLanding ? Int((base * 0.10).rounded()) : 0,
            latePenalty: Int((base * (lateFrac + comfortFrac)).rounded()),
            damagePenalty: Int(rough.rounded()),
            fuelCost: fuel)
    }
}
