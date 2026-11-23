// SKYFORGE — Apache-2.0
// The player's fleet: buying, selling, storage, servicing, flights and daily upkeep.
// Pure value type with no UI or rendering dependency, so it runs headless on Linux.
import Foundation

/// Usage from one flight. The flight session reports this when a flight ends.
public struct FlightUsage: Sendable, Equatable {
    public var hours: Double
    public var landings: Int
    public var hardLandings: Int

    public init(hours: Double, landings: Int, hardLandings: Int = 0) {
        self.hours = hours; self.landings = landings; self.hardLandings = hardLandings
    }
}

public struct Fleet: Sendable, Codable, Equatable {
    public static let startingBalance = Credits(250_000)

    public private(set) var aircraft: [OwnedAircraft]
    public private(set) var wallet: Wallet
    public private(set) var day: Int
    private var nextSerial: Int

    public init(wallet: Wallet = Wallet(balance: Fleet.startingBalance)) {
        self.aircraft = []
        self.wallet = wallet
        self.day = 0
        self.nextSerial = 1
    }

    public func aircraft(id: String) -> OwnedAircraft? {
        aircraft.first { $0.id == id }
    }

    /// Buys an aircraft and returns its id. Nothing changes if the purchase fails.
    @discardableResult
    public mutating func purchase(_ model: AircraftModel, condition: AircraftCondition = .new,
                                  storage: Storage = .tieDown) throws -> String {
        guard condition.isValid else { throw CareerError.invalidCondition }
        let price = condition.price(for: model)
        try wallet.spend(price, day: day, reason: "Purchase \(model.name)")
        let id = "AC-\(nextSerial)"
        nextSerial += 1
        var components: [AircraftComponent: ComponentState] = [:]
        for component in AircraftComponent.allCases {
            components[component] = ComponentState(wear: condition.initialWear)
        }
        aircraft.append(OwnedAircraft(id: id, model: model, purchasePrice: price, storage: storage, components: components))
        return id
    }

    /// Sells at resale value and removes the aircraft from the fleet.
    public mutating func sell(id: String) throws {
        let index = try indexOf(id)
        let value = aircraft[index].resaleValue
        let name = aircraft[index].model.name
        try wallet.earn(value, day: day, reason: "Sale of \(name) \(id)")
        aircraft.remove(at: index)
    }

    /// Moves the aircraft to other storage. The move costs five days of the new storage's rent.
    public mutating func changeStorage(id: String, to storage: Storage) throws {
        let index = try indexOf(id)
        guard aircraft[index].storage != storage else { return }
        let fee = Credits(storage.dailyRent.amount * 5)
        try wallet.spend(fee, day: day, reason: "Move \(id) to \(storage.displayName)")
        aircraft[index].storage = storage
        aircraft[index].appendLog(day: day, component: nil, kind: .storage(storage), cost: fee,
                                  note: "Moved to \(storage.displayName)")
    }

    /// Performs maintenance on one component and charges for it.
    public mutating func service(id: String, component: AircraftComponent, action: ServiceAction) throws {
        let index = try indexOf(id)
        let cost = action.cost(for: component, on: aircraft[index].model)
        try wallet.spend(cost, day: day, reason: "\(action.rawValue) \(component.rawValue) on \(id)")
        var state = aircraft[index].components[component, default: ComponentState()]
        switch action {
        case .inspection:
            state.hoursSinceService = 0
        case .repair:
            state.defect = false
            state.wear = max(0, state.wear - ServiceAction.repairWearRelief)
        case .overhaul:
            state = ComponentState(wear: 0, hoursSinceService: 0, defect: false)
        }
        aircraft[index].components[component] = state
        aircraft[index].appendLog(day: day, component: component, kind: .service(action), cost: cost,
                                  note: "\(action.rawValue) \(component.rawValue)")
    }

    /// Records a finished flight, applies wear and rolls for in-flight failures.
    /// Returns the components that failed. Grounded aircraft cannot fly.
    @discardableResult
    public mutating func recordFlight<G: RandomNumberGenerator>(id: String, usage: FlightUsage,
                                                                using rng: inout G) throws -> [AircraftComponent] {
        let index = try indexOf(id)
        if case .grounded(let components) = aircraft[index].dispatchStatus {
            throw CareerError.grounded(id, components: components)
        }
        guard usage.hours >= 0, usage.landings >= 0, usage.hardLandings >= 0 else { throw CareerError.invalidAmount }

        aircraft[index].totalHours += usage.hours
        aircraft[index].totalLandings += usage.landings

        var failed: [AircraftComponent] = []
        for component in AircraftComponent.allCases {
            var state = aircraft[index].components[component, default: ComponentState()]
            let rule = component.rule
            state.wear += usage.hours * rule.wearPerFlightHour + Double(usage.landings) * rule.wearPerLanding
            if component == .airframe {
                state.wear += Double(usage.hardLandings) * FailureModel.hardLandingWear
            }
            state.hoursSinceService += usage.hours

            let perHour = FailureModel.chancePerFlightHour(wear: state.wear)
            let failChance = perHour > 0 && usage.hours > 0 ? 1 - pow(1 - perHour, usage.hours) : 0
            if failChance > 0, Double.random(in: 0..<1, using: &rng) < failChance {
                state.defect = true
                state.wear += FailureModel.defectWearGain
                failed.append(component)
                aircraft[index].appendLog(day: day, component: component, kind: .failure, cost: .zero,
                                          note: "In-flight \(component.rawValue) failure")
            }
            aircraft[index].components[component] = state
        }
        return failed
    }

    /// Advances the calendar. Charges daily rent and applies tie-down weather wear.
    /// If rent cannot be paid, the aircraft drops to tie-down. Unpaid tie-down rent is not charged.
    public mutating func advanceDays(_ days: Int) {
        guard days > 0 else { return }
        for _ in 0..<days {
            day += 1
            for index in aircraft.indices {
                for component in AircraftComponent.allCases {
                    let exposure = aircraft[index].storage.dailyExposureWear(for: component)
                    if exposure > 0 {
                        aircraft[index].components[component, default: ComponentState()].wear += exposure
                    }
                }
                let rent = aircraft[index].storage.dailyRent
                let id = aircraft[index].id
                if (try? wallet.spend(rent, day: day, reason: "Rent \(id)")) != nil {
                    continue
                }
                if aircraft[index].storage != .tieDown {
                    let previous = aircraft[index].storage.displayName
                    aircraft[index].storage = .tieDown
                    aircraft[index].appendLog(day: day, component: nil, kind: .storage(.tieDown), cost: .zero,
                                              note: "Could not pay rent; moved from \(previous) to tie-down")
                }
            }
        }
    }

    private func indexOf(_ id: String) throws -> Int {
        guard let index = aircraft.firstIndex(where: { $0.id == id }) else {
            throw CareerError.unknownAircraft(id)
        }
        return index
    }
}
