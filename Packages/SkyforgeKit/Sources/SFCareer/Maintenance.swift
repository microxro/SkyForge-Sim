// SKYFORGE — Apache-2.0
// Aircraft wear, servicing, in-flight failures and sales. Lives in the career layer so it saves with the profile.
// Every number here is game balance, not engineering data. Deterministic: the same flight always rolls the same way.
import Foundation
import SFMath

public enum AircraftComponent: String, Codable, Sendable, CaseIterable {
    case engine, propeller, brakes, tires, airframe, avionics
}

public struct ComponentRule: Sendable, Equatable {
    /// Flight hours between inspections.
    public let serviceIntervalHours: Double
    /// Wear (0 new, 1 end of life) per flight hour.
    public let wearPerFlightHour: Double
    /// Wear per landing.
    public let wearPerLanding: Double
    /// Overhaul cost as a share of the aircraft's reference price.
    public let overhaulFraction: Double
}

extension AircraftComponent {
    public var rule: ComponentRule {
        switch self {
        case .engine:   return ComponentRule(serviceIntervalHours: 100, wearPerFlightHour: 1.0 / 1_500, wearPerLanding: 0, overhaulFraction: 0.22)
        case .propeller: return ComponentRule(serviceIntervalHours: 200, wearPerFlightHour: 1.0 / 2_500, wearPerLanding: 0, overhaulFraction: 0.05)
        case .brakes:   return ComponentRule(serviceIntervalHours: 150, wearPerFlightHour: 0, wearPerLanding: 1.0 / 350, overhaulFraction: 0.02)
        case .tires:    return ComponentRule(serviceIntervalHours: 80, wearPerFlightHour: 0, wearPerLanding: 1.0 / 250, overhaulFraction: 0.01)
        case .airframe: return ComponentRule(serviceIntervalHours: 400, wearPerFlightHour: 1.0 / 4_000, wearPerLanding: 0, overhaulFraction: 0.10)
        case .avionics: return ComponentRule(serviceIntervalHours: 500, wearPerFlightHour: 1.0 / 6_000, wearPerLanding: 0, overhaulFraction: 0.04)
        }
    }
}

public enum MaintenanceRules {
    /// The starter aircraft has no purchase price, so its servicing is costed against this reference value.
    public static let starterAircraftID = "org.skyforge.sf1"
    public static let starterReferencePrice = 30_000
    /// Landing sink rate above which a landing counts as hard (fpm).
    public static let hardLandingSinkFPM = 600.0
    public static let crashAirframeWear = 0.3
    public static let maxHistory = 100

    /// Reference price used for servicing and resale. Bought aircraft use their catalogue price.
    public static func referencePrice(for spec: HangarAircraft) -> Int {
        spec.purchasePrice > 0 ? spec.purchasePrice : starterReferencePrice
    }
}

public enum ServiceAction: String, Codable, Sendable, CaseIterable {
    /// Resets the service interval. No wear change.
    case inspection
    /// Clears a defect and removes some wear.
    case repair
    /// Resets wear, the service interval and any defect.
    case overhaul

    public static let repairWearRelief = 0.25

    /// Share of the component's overhaul cost.
    public var costShare: Double {
        switch self {
        case .inspection: return 0.08
        case .repair: return 0.5
        case .overhaul: return 1
        }
    }

    public func cost(for component: AircraftComponent, referencePrice: Int) -> Int {
        let overhaul = Double(referencePrice) * component.rule.overhaulFraction
        return Int((overhaul * costShare).rounded())
    }
}

public enum FailureModel {
    /// Wear above this starts to raise in-flight failure chances.
    public static let wearThreshold = 0.8
    /// Wear added when a failure leaves a defect.
    public static let defectWearGain = 0.05
    /// Extra airframe wear per hard landing.
    public static let hardLandingWear = 0.02

    /// Chance of a failure in one flight hour at this wear. Capped at 5%.
    public static func chancePerFlightHour(wear: Double) -> Double {
        guard wear > wearThreshold else { return 0 }
        return min(0.05, (wear - wearThreshold) * 0.25)
    }
}

public struct ComponentWear: Codable, Sendable, Equatable {
    /// 0 is new, 1 is end of life.
    public var wear: Double
    public var hoursSinceService: Double
    /// Set by an in-flight failure or a crash. Grounds the aircraft until repaired or overhauled.
    public var defect: Bool

    public init(wear: Double = 0, hoursSinceService: Double = 0, defect: Bool = false) {
        self.wear = wear
        self.hoursSinceService = hoursSinceService
        self.defect = defect
    }
}

public enum MaintenanceEventKind: Codable, Sendable, Equatable {
    case service(ServiceAction)
    case failure
    case crash
}

/// One line in an aircraft's maintenance history.
public struct MaintenanceEvent: Codable, Sendable, Equatable {
    public var kind: MaintenanceEventKind
    public var component: AircraftComponent
    public var credits: Int

    public init(kind: MaintenanceEventKind, component: AircraftComponent, credits: Int) {
        self.kind = kind; self.component = component; self.credits = credits
    }
}

/// Per-aircraft maintenance state. Keyed by aircraft id in `CareerState.maintenance`.
public struct AircraftMaintenance: Codable, Sendable, Equatable {
    /// Keyed by `AircraftComponent.rawValue`, so the save file reads as a plain JSON object.
    public var components: [String: ComponentWear]
    public var totalHours: Double
    public var history: [MaintenanceEvent]

    public init(components: [String: ComponentWear] = [:], totalHours: Double = 0, history: [MaintenanceEvent] = []) {
        self.components = components
        self.totalHours = totalHours
        self.history = history
    }

    public func wear(_ component: AircraftComponent) -> ComponentWear {
        components[component.rawValue] ?? ComponentWear()
    }

    public mutating func set(_ component: AircraftComponent, _ state: ComponentWear) {
        components[component.rawValue] = state
    }

    public mutating func record(_ event: MaintenanceEvent) {
        history.append(event)
        if history.count > MaintenanceRules.maxHistory { history.removeFirst(history.count - MaintenanceRules.maxHistory) }
    }

    public var averageWear: Double {
        let all = AircraftComponent.allCases
        return all.reduce(0.0) { $0 + wear($1).wear } / Double(all.count)
    }

    public var hasDefect: Bool { AircraftComponent.allCases.contains { wear($0).defect } }

    public var dispatchStatus: DispatchStatus {
        var warnings: [AircraftComponent] = []
        var grounds: [AircraftComponent] = []
        for component in AircraftComponent.allCases {
            let state = wear(component)
            let interval = component.rule.serviceIntervalHours
            if state.defect || state.wear >= 1 || state.hoursSinceService >= interval * 1.2 {
                grounds.append(component)
            } else if state.wear >= FailureModel.wearThreshold || state.hoursSinceService >= interval {
                warnings.append(component)
            }
        }
        if !grounds.isEmpty { return .grounded(grounds) }
        if !warnings.isEmpty { return .warning(warnings) }
        return .serviceable
    }
}

public enum DispatchStatus: Sendable, Equatable {
    case serviceable
    /// Can fly, but something is due or close to end of life.
    case warning([AircraftComponent])
    /// Cannot fly until the listed components are serviced.
    case grounded([AircraftComponent])
}

public enum MaintenanceError: Error, Sendable, Equatable {
    case notOwned
    case starterAircraft
    case insufficientFunds(short: Int)
}

extension CareerState {
    public func maintenanceState(for aircraftID: String) -> AircraftMaintenance {
        maintenance[aircraftID] ?? AircraftMaintenance()
    }

    public func dispatchStatus(for aircraftID: String) -> DispatchStatus {
        maintenanceState(for: aircraftID).dispatchStatus
    }

    /// Resale value: purchase price, less 45% at 8,000 hours, less up to half of it for average wear,
    /// less 10% while any defect is open. Floors at 15% of the reference price, so a sale is never worthless.
    public func resaleValue(for aircraftID: String, catalog: [HangarAircraft] = Economy.catalog) -> Int? {
        guard ownedAircraft.contains(aircraftID), let spec = Economy.spec(aircraftID, in: catalog) else { return nil }
        let m = maintenanceState(for: aircraftID)
        let reference = Double(MaintenanceRules.referencePrice(for: spec))
        let hoursFactor = max(0.15, 1 - m.totalHours / 8_000)
        let wearFactor = max(0.2, 1 - 0.5 * m.averageWear)
        let defectFactor = m.hasDefect ? 0.9 : 1.0
        return Int((reference * hoursFactor * wearFactor * defectFactor).rounded())
    }

    /// Pays for one maintenance action on one component and records it in the aircraft's history.
    @discardableResult
    public mutating func service(aircraftID: String, component: AircraftComponent, action: ServiceAction,
                                 catalog: [HangarAircraft] = Economy.catalog) throws -> Int {
        guard ownedAircraft.contains(aircraftID), let spec = Economy.spec(aircraftID, in: catalog) else {
            throw MaintenanceError.notOwned
        }
        let cost = action.cost(for: component, referencePrice: MaintenanceRules.referencePrice(for: spec))
        guard credits >= cost else { throw MaintenanceError.insufficientFunds(short: cost - credits) }
        credits -= cost

        var m = maintenanceState(for: aircraftID)
        var state = m.wear(component)
        switch action {
        case .inspection:
            state.hoursSinceService = 0
        case .repair:
            state.defect = false
            state.wear = max(0, state.wear - ServiceAction.repairWearRelief)
        case .overhaul:
            state = ComponentWear()
        }
        m.set(component, state)
        m.record(MaintenanceEvent(kind: .service(action), component: component, credits: cost))
        maintenance[aircraftID] = m
        return cost
    }

    /// Sells an owned aircraft at resale value. The starter aircraft cannot be sold.
    @discardableResult
    public mutating func sell(aircraftID: String, catalog: [HangarAircraft] = Economy.catalog) throws -> Int {
        guard aircraftID != MaintenanceRules.starterAircraftID else { throw MaintenanceError.starterAircraft }
        guard let value = resaleValue(for: aircraftID, catalog: catalog) else { throw MaintenanceError.notOwned }
        ownedAircraft.remove(aircraftID)
        maintenance[aircraftID] = nil
        credits = min(credits + value, CareerState.maxCredits)
        return value
    }

    /// Clamps maintenance data from a save: only owned aircraft, finite numbers, bounded history.
    static func sanitizedMaintenance(_ raw: [String: AircraftMaintenance], owned: Set<String>) -> [String: AircraftMaintenance] {
        var out: [String: AircraftMaintenance] = [:]
        for (id, m) in raw.prefix(500) where owned.contains(id) && validID(id) {
            var clean = AircraftMaintenance()
            clean.totalHours = m.totalHours.isFinite ? min(max(m.totalHours, 0), 1_000_000) : 0
            for c in AircraftComponent.allCases {
                let w = m.wear(c)
                clean.set(c, ComponentWear(
                    wear: w.wear.isFinite ? min(max(w.wear, 0), 2) : 0,
                    hoursSinceService: w.hoursSinceService.isFinite ? min(max(w.hoursSinceService, 0), 1_000_000) : 0,
                    defect: w.defect))
            }
            clean.history = Array(m.history.suffix(MaintenanceRules.maxHistory))
            out[id] = clean
        }
        return out
    }
}

/// Flight-driven wear and failure rolls. Called from `CareerEngine.apply` for owned aircraft.
enum FlightWear {
    /// Applies one flight to the aircraft's maintenance state and returns components that failed in flight.
    static func apply(_ r: FlightReport, to state: inout CareerState) -> [AircraftComponent] {
        guard state.ownedAircraft.contains(r.aircraftID) else { return [] }
        var m = state.maintenanceState(for: r.aircraftID)
        let hours = r.durationS / 3_600
        let landings = (r.landed && !r.crashed) ? 1 : 0
        let hard = (r.touchdownSinkFPM ?? 0) > MaintenanceRules.hardLandingSinkFPM ? 1 : 0
        m.totalHours += hours

        // Deterministic per flight: same flight, same roll, so replays and tests agree.
        var rng = Xoshiro256(seed: Hash.mix(UInt64(bitPattern: Int64(r.endedAt))) ^ fnv1a(r.aircraftID))
        var failed: [AircraftComponent] = []
        for component in AircraftComponent.allCases {
            var w = m.wear(component)
            let rule = component.rule
            w.wear += hours * rule.wearPerFlightHour + Double(landings) * rule.wearPerLanding
            if component == .airframe { w.wear += Double(hard) * FailureModel.hardLandingWear }
            w.hoursSinceService += hours

            let perHour = FailureModel.chancePerFlightHour(wear: w.wear)
            let chance = perHour > 0 && hours > 0 ? 1 - pow(1 - perHour, hours) : 0
            let roll = Double(rng.next() % 1_000_000) / 1_000_000
            if chance > 0 && roll < chance {
                w.defect = true
                w.wear += FailureModel.defectWearGain
                failed.append(component)
                m.record(MaintenanceEvent(kind: .failure, component: component, credits: 0))
            }
            m.set(component, w)
        }
        if r.crashed {
            var w = m.wear(.airframe)
            w.wear += MaintenanceRules.crashAirframeWear
            w.defect = true
            m.set(.airframe, w)
            failed.append(.airframe)
            m.record(MaintenanceEvent(kind: .crash, component: .airframe, credits: 0))
        }
        state.maintenance[r.aircraftID] = m
        return failed
    }

    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}
