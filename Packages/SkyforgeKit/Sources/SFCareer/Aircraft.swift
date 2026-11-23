// SKYFORGE — Apache-2.0
// Owned aircraft: model catalogue, purchase condition, storage, maintenance log and resale value.
import Foundation

public struct AircraftModel: Sendable, Codable, Equatable, Identifiable {
    /// Matches the aircraft config id (`AircraftConfig.sf1Trainer.id`).
    public let id: String
    public let name: String
    public let newPrice: Credits

    public init(id: String, name: String, newPrice: Credits) {
        self.id = id; self.name = name; self.newPrice = newPrice
    }

    public static let sf1Trainer = AircraftModel(id: "org.skyforge.sf1", name: "SF-1 Trainer", newPrice: Credits(180_000))

    public static let catalog: [AircraftModel] = [sf1Trainer]
}

public enum AircraftCondition: Sendable, Codable, Equatable {
    case new
    /// Used aircraft start with this wear on every component. Valid range is 0 to 0.9.
    case used(wear: Double)

    public var initialWear: Double {
        switch self {
        case .new: return 0
        case .used(let wear): return wear
        }
    }

    public var isValid: Bool { initialWear >= 0 && initialWear <= 0.9 }

    /// Used aircraft lose up to 60% of the new price as wear rises.
    public func price(for model: AircraftModel) -> Credits {
        let factor = 1 - 0.6 * initialWear
        return Credits(Int((Double(model.newPrice.amount) * factor).rounded()))
    }
}

public enum HangarTier: String, Sendable, Codable, CaseIterable {
    case tHangar
    case largeHangar
}

public enum Storage: Sendable, Codable, Equatable {
    case tieDown
    case hangar(HangarTier)

    public var displayName: String {
        switch self {
        case .tieDown: return "tie-down"
        case .hangar(.tHangar): return "T-hangar"
        case .hangar(.largeHangar): return "large hangar"
        }
    }

    public var dailyRent: Credits {
        switch self {
        case .tieDown: return Credits(25)
        case .hangar(.tHangar): return Credits(120)
        case .hangar(.largeHangar): return Credits(300)
        }
    }

    /// Weather wear per day. Only tie-down storage is exposed.
    public func dailyExposureWear(for component: AircraftComponent) -> Double {
        guard case .tieDown = self else { return 0 }
        switch component {
        case .airframe: return 1.0 / 2_500
        case .avionics: return 1.0 / 6_000
        default: return 0
        }
    }
}

public enum LogKind: Sendable, Codable, Equatable {
    case service(ServiceAction)
    case failure
    case storage(Storage)
}

/// One line in an aircraft's maintenance log.
public struct MaintenanceEntry: Sendable, Codable, Equatable {
    public let day: Int
    public let component: AircraftComponent?
    public let kind: LogKind
    public let cost: Credits
    public let note: String

    public init(day: Int, component: AircraftComponent?, kind: LogKind, cost: Credits, note: String) {
        self.day = day; self.component = component; self.kind = kind; self.cost = cost; self.note = note
    }
}

public struct OwnedAircraft: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let model: AircraftModel
    public let purchasePrice: Credits
    public var storage: Storage
    public var components: [AircraftComponent: ComponentState]
    public var totalHours: Double
    public var totalLandings: Int
    public var maintenanceLog: [MaintenanceEntry]

    public init(id: String, model: AircraftModel, purchasePrice: Credits, storage: Storage,
                components: [AircraftComponent: ComponentState], totalHours: Double = 0,
                totalLandings: Int = 0, maintenanceLog: [MaintenanceEntry] = []) {
        self.id = id
        self.model = model
        self.purchasePrice = purchasePrice
        self.storage = storage
        self.components = components
        self.totalHours = totalHours
        self.totalLandings = totalLandings
        self.maintenanceLog = maintenanceLog
    }

    public var averageWear: Double {
        let all = AircraftComponent.allCases
        let total = all.reduce(0.0) { $0 + components[$1, default: ComponentState()].wear }
        return total / Double(all.count)
    }

    /// Resale falls with airframe hours (floor 15%), with average wear, and by 10% while any defect is open.
    public var resaleValue: Credits {
        let hoursFactor = max(0.15, 1 - totalHours / 8_000)
        let wearFactor = max(0.2, 1 - 0.5 * averageWear)
        let defectFactor = components.values.contains { $0.defect } ? 0.9 : 1.0
        let value = Double(model.newPrice.amount) * hoursFactor * wearFactor * defectFactor
        return Credits(Int(value.rounded()))
    }

    mutating func appendLog(day: Int, component: AircraftComponent?, kind: LogKind, cost: Credits, note: String) {
        maintenanceLog.append(MaintenanceEntry(day: day, component: component, kind: kind, cost: cost, note: note))
    }
}
