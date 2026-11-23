// SKYFORGE — Apache-2.0
// In-game credits only. Nothing here touches real money: credits are earned and spent inside the game.
import Foundation

/// Whole in-game credits.
public struct Credits: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public var amount: Int

    public init(_ amount: Int) { self.amount = amount }

    public static let zero = Credits(0)

    public static func + (lhs: Credits, rhs: Credits) -> Credits { Credits(lhs.amount + rhs.amount) }
    public static func - (lhs: Credits, rhs: Credits) -> Credits { Credits(lhs.amount - rhs.amount) }
    public static func < (lhs: Credits, rhs: Credits) -> Bool { lhs.amount < rhs.amount }

    public var description: String { "\(amount) cr" }
}

public enum CareerError: Error, Sendable, Equatable {
    case invalidAmount
    case insufficientFunds(required: Credits, available: Credits)
    case unknownAircraft(String)
    case invalidCondition
    case grounded(String, components: [AircraftComponent])
}

public struct LedgerEntry: Sendable, Codable, Equatable {
    public let day: Int
    /// Positive for income, negative for spending.
    public let amount: Credits
    public let reason: String

    public init(day: Int, amount: Credits, reason: String) {
        self.day = day; self.amount = amount; self.reason = reason
    }
}

public struct Wallet: Sendable, Codable, Equatable {
    public private(set) var balance: Credits
    public private(set) var ledger: [LedgerEntry]

    public init(balance: Credits = .zero) {
        self.balance = balance
        self.ledger = []
    }

    public mutating func earn(_ amount: Credits, day: Int, reason: String) throws {
        guard amount.amount >= 0 else { throw CareerError.invalidAmount }
        balance = balance + amount
        ledger.append(LedgerEntry(day: day, amount: amount, reason: reason))
    }

    public mutating func spend(_ amount: Credits, day: Int, reason: String) throws {
        guard amount.amount >= 0 else { throw CareerError.invalidAmount }
        guard balance >= amount else {
            throw CareerError.insufficientFunds(required: amount, available: balance)
        }
        balance = balance - amount
        ledger.append(LedgerEntry(day: day, amount: Credits(-amount.amount), reason: reason))
    }
}
