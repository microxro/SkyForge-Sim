// SKYFORGE — Apache-2.0
// Exploration: real-world landmarks and scenic points the pilot discovers by flying near them.
// Pure data and geometry. The gameplay layer reports which spots a flight came within range of, and the
// career layer awards each spot once.
import Foundation

public enum DiscoveryKind: String, Codable, Sendable, CaseIterable {
    case landmark
    case scenicPoint

    public var title: String {
        switch self {
        case .landmark: return "Landmark"
        case .scenicPoint: return "Scenic Point"
        }
    }
}

public struct Discovery: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: DiscoveryKind
    public let latitudeDeg: Double
    public let longitudeDeg: Double
    /// The pilot must pass within this distance (km) to discover the spot.
    public let radiusKm: Double
    public let xp: Int
}

public enum Discoveries {
    /// Upper bound on new discoveries credited from one flight, so a bad input can never flood the profile.
    public static let maxAwardsPerFlight = 20

    public static let all: [Discovery] = landmarks + scenicPoints
    static let byID: [String: Discovery] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Whether an identifier names a catalogue entry.
    public static func isKnown(_ id: String) -> Bool { byID[id] != nil }

    private static func landmark(_ id: String, _ name: String, _ lat: Double, _ lon: Double, radius: Double = 25) -> Discovery {
        Discovery(id: id, name: name, kind: .landmark, latitudeDeg: lat, longitudeDeg: lon, radiusKm: radius, xp: 150)
    }

    private static func scenic(_ id: String, _ name: String, _ lat: Double, _ lon: Double, radius: Double = 20) -> Discovery {
        Discovery(id: id, name: name, kind: .scenicPoint, latitudeDeg: lat, longitudeDeg: lon, radiusKm: radius, xp: 100)
    }

    static let landmarks: [Discovery] = [
        landmark("golden-gate", "Golden Gate Bridge", 37.8199, -122.4783, radius: 10),
        landmark("statue-of-liberty", "Statue of Liberty", 40.6892, -74.0445, radius: 10),
        landmark("eiffel-tower", "Eiffel Tower", 48.8584, 2.2945, radius: 10),
        landmark("big-ben", "Big Ben", 51.5007, -0.1246, radius: 10),
        landmark("sydney-opera-house", "Sydney Opera House", -33.8568, 151.2153, radius: 10),
        landmark("burj-khalifa", "Burj Khalifa", 25.1972, 55.2744, radius: 10),
        landmark("christ-the-redeemer", "Christ the Redeemer", -22.9519, -43.2105, radius: 10),
        landmark("machu-picchu", "Machu Picchu", -13.1631, -72.5450, radius: 10),
        landmark("giza-pyramids", "Pyramids of Giza", 29.9792, 31.1342, radius: 10),
        landmark("taj-mahal", "Taj Mahal", 27.1751, 78.0421, radius: 10),
        landmark("colosseum", "Colosseum", 41.8902, 12.4922, radius: 10),
        landmark("acropolis", "Acropolis of Athens", 37.9715, 23.7257, radius: 10),
        landmark("stonehenge", "Stonehenge", 51.1789, -1.8262, radius: 10),
        landmark("mount-rushmore", "Mount Rushmore", 43.8791, -103.4591, radius: 10),
        landmark("mount-fuji", "Mount Fuji", 35.3606, 138.7274, radius: 25),
        landmark("mount-everest", "Mount Everest", 27.9881, 86.9250, radius: 30),
        landmark("mount-kilimanjaro", "Mount Kilimanjaro", -3.0674, 37.3556, radius: 25),
        landmark("denali", "Denali", 63.0694, -151.0070, radius: 30),
        landmark("uluru", "Uluru", -25.3444, 131.0369, radius: 15),
        landmark("victoria-falls", "Victoria Falls", -17.9243, 25.8572, radius: 15),
    ]

    static let scenicPoints: [Discovery] = [
        scenic("grand-canyon", "Grand Canyon, Mather Point", 36.0617, -112.1247, radius: 30),
        scenic("half-dome", "Half Dome, Yosemite", 37.7459, -119.5332),
        scenic("monument-valley", "Monument Valley", 36.9980, -110.0985),
        scenic("lake-tahoe", "Lake Tahoe", 39.0968, -120.0324, radius: 30),
        scenic("lake-louise", "Lake Louise", 51.4254, -116.1773),
        scenic("milford-sound", "Milford Sound", -44.6414, 167.8974),
        scenic("aoraki-cook", "Aoraki / Mount Cook", -43.5950, 170.1400, radius: 30),
        scenic("table-mountain", "Table Mountain", -33.9628, 18.4098),
        scenic("angel-falls", "Angel Falls", 5.9674, -62.5361),
        scenic("iguazu-falls", "Iguazu Falls", -25.6953, -54.4367),
        scenic("niagara-falls", "Niagara Falls", 43.0796, -79.0849),
        scenic("mount-st-helens", "Mount St. Helens", 46.1914, -122.1956),
        scenic("kilauea", "Kilauea Caldera", 19.4210, -155.2870),
        scenic("matterhorn", "Matterhorn", 45.9763, 7.6586),
        scenic("mont-blanc", "Mont Blanc", 45.8326, 6.8652, radius: 30),
        scenic("santorini", "Santorini, Oia", 36.4618, 25.3753),
    ]

    /// Catalogue spots whose discovery radius contains the position. Non-finite or out-of-range input finds nothing.
    public static func spots(nearLatitude lat: Double, longitude lon: Double) -> [Discovery] {
        guard lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 else { return [] }
        return all.filter { distanceKm(lat1: lat, lon1: lon, lat2: $0.latitudeDeg, lon2: $0.longitudeDeg) <= $0.radiusKm }
    }

    /// Great-circle distance in km (haversine).
    public static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKm = 6_371.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dLat = (lat2 - lat1) * .pi / 180, dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        guard a.isFinite else { return .infinity }
        return 2 * earthRadiusKm * asin(min(1, sqrt(max(0, a))))
    }

    /// The reached spots that are not yet known: each once, in the order reached, capped per flight.
    public static func newIDs(reached: [String], known: Set<String>) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in reached {
            guard isKnown(id), !known.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(id)
            if out.count == maxAwardsPerFlight { break }
        }
        return out
    }
}
