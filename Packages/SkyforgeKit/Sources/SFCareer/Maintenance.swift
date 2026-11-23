// SKYFORGE — Apache-2.0
// Component wear, service intervals, defects and dispatch status. Numbers are game balance, not engineering data.
import Foundation

public enum AircraftComponent: String, Sendable, Codable, CaseIterable {
    case engine, propeller, brakes, tires, airframe, avionics
}

public struct ComponentRule: Sendable, Equatable {
    /// Flight hours between inspections.
    public let serviceIntervalHours: Double
    /// Wear (0 new, 1 end of life) added per flight hour.
    public let wearPerFlightHour: Double
    /// Wear added per landing.
    public let wearPerLanding: Double
    /// Overhaul cost as a share of the aircraft's new price.
    public let overhaulFraction: Double

    public init(serviceIntervalHours: Double, wearPerFlightHour: Double, wearPerLanding: Double, overhaulFraction: Double) {
        self.serviceIntervalHours = serviceIntervalHours
        self.wearPerFlightHour = wearPerFlightHour
        self.wearPerLanding = wearPerLanding
        self.overhaulFraction = overhaulFraction
    }
}

extension AircraftComponent {
    public var rule: ComponentRule {
        switch self {
        case .engine:
            return ComponentRule(serviceIntervalHours: 100, wearPerFlightHour: 1.0 / 1_500, wearPerLanding: 0, overhaulFraction: 0.22)
        case .propeller:
            return ComponentRule(serviceIntervalHours: 200, wearPerFlightHour: 1.0 / 2_500, wearPerLanding: 0, overhaulFraction: 0.05)
        case .brakes:
            return ComponentRule(serviceIntervalHours: 150, wearPerFlightHour: 0, wearPerLanding: 1.0 / 350, overhaulFraction: 0.02)
        case .tires:
            return ComponentRule(serviceIntervalHours: 80, wearPerFlightHour: 0, wearPerLanding: 1.0 / 250, overhaulFraction: 0.01)
        case .airframe:
            return ComponentRule(serviceIntervalHours: 400, wearPerFlightHour: 1.0 / 4_000, wearPerLanding: 0, overhaulFraction: 0.10)
        case .avionics:
            return ComponentRule(serviceIntervalHours: 500, wearPerFlightHour: 1.0 / 6_000, wearPerLanding: 0, overhaulFraction: 0.04)
        }
    }
}

public struct ComponentState: Sendable, Codable, Equatable {
    /// 0 is new, 1 is end of life.
    public var wear: Double
    public var hoursSinceService: Double
    /// Set by an in-flight failure. Grounds the aircraft until repaired or overhauled.
    public var defect: Bool

    public init(wear: Double = 0, hoursSinceService: Double = 0, defect: Bool = false) {
        self.wear = wear
        self.hoursSinceService = hoursSinceService
        self.defect = defect
    }
}

public enum ServiceAction: String, Sendable, Codable, CaseIterable {
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

    public func cost(for component: AircraftComponent, on model: AircraftModel) -> Credits {
        let overhaul = Double(model.newPrice.amount) * component.rule.overhaulFraction
        return Credits(Int((overhaul * costShare).rounded()))
    }
}

public enum FailureModel {
    /// Wear above this starts to raise in-flight failure chances.
    public static let wearThreshold = 0.8
    /// Wear added when a failure leaves a defect.
    public static let defectWearGain = 0.05
    /// Extra airframe wear per hard landing.
    public static let hardLandingWear = 0.02

    /// Probability of a failure in one flight hour, at the given wear. Capped at 5%.
    public static func chancePerFlightHour(wear: Double) -> Double {
        guard wear > wearThreshold else { return 0 }
        return min(0.05, (wear - wearThreshold) * 0.25)
    }
}

public enum DispatchStatus: Sendable, Equatable {
    case serviceable
    /// Can fly, but something is due or close to end of life.
    case warning([AircraftComponent])
    /// Cannot fly until the listed components are serviced.
    case grounded([AircraftComponent])
}

extension OwnedAircraft {
    public var dispatchStatus: DispatchStatus {
        var warnings: [AircraftComponent] = []
        var grounds: [AircraftComponent] = []
        for component in AircraftComponent.allCases {
            let state = components[component, default: ComponentState()]
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
