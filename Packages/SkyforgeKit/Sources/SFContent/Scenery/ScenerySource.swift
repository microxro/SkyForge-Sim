// SKYFORGE — Apache-2.0
// Where scenery comes from at a given point: an installed whole-Earth segment, or the procedural world.
// The procedural world is always there, so flight never blocks on the download.
import Foundation

public enum ScenerySource: Equatable, Sendable {
    case earthSegment(id: String)
    case procedural
}

public enum ScenerySourceResolver {
    /// First installed segment that covers the point, in catalog order. Procedural when none does.
    public static func source(latitude: Double, longitude: Double,
                              catalog: SceneryCatalog?, installed: Set<String>) -> ScenerySource {
        guard let catalog else { return .procedural }
        for s in catalog.segments where installed.contains(s.id) && s.bounds.contains(latitude: latitude, longitude: longitude) {
            return .earthSegment(id: s.id)
        }
        return .procedural
    }
}

/// Network rules for the download: Wi-Fi only by default, and never on a constrained or expensive link
/// unless the player turns cellular on.
public struct ScenerySyncNetworkPolicy: Sendable, Equatable {
    public enum Link: Sendable, Equatable { case wifi, cellular, none }

    public var allowCellular: Bool
    public var link: Link
    public var isExpensiveOrConstrained: Bool

    public init(allowCellular: Bool = false, link: Link, isExpensiveOrConstrained: Bool = false) {
        self.allowCellular = allowCellular
        self.link = link
        self.isExpensiveOrConstrained = isExpensiveOrConstrained
    }

    /// Nil when downloads may run now; otherwise the reason they wait.
    public var blockingFailure: SceneryFailure? {
        switch link {
        case .none: return .network
        case .wifi: return nil
        case .cellular:
            if allowCellular && !isExpensiveOrConstrained { return nil }
            return .waitingForWiFi
        }
    }
}
