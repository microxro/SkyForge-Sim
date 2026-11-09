// SKYFORGE — Apache-2.0
// OpenStreetMap buildings and roads for the real-world Quick Flight: an Overpass API query for
// the region's bounding box, a parser for its JSON (`out geom`) into local tangent-plane metres,
// a cached fetch service that never blocks flight (nil when offline with nothing cached, so the
// caller keeps procedural buildings) and Linux-testable mesh generation (extruded walls,
// ear-clipped flat roofs, terrain-draped road ribbons).
// Data © OpenStreetMap contributors, ODbL 1.0 — show `OSMData.attribution` whenever it is drawn.
import Foundation
import SFMath
import SFContent
import SFImagery
import SFPreview
import SFWorldGen

// MARK: - Model

/// A building footprint from a `building=*` or `building:part=*` way.
public struct OSMBuilding: Sendable, Equatable {
    public var id: Int64
    /// Local metres (x east, y north), counter-clockwise, closed ring without a repeated last point.
    public var footprint: [SIMD2<Double>]
    /// Top of the walls above the ground (OSM `height`, or estimated from levels/type).
    public var heightMetres: Double
    /// Bottom of the walls above the ground (`min_height` / `building:min_level`); 0 for most buildings.
    public var minHeightMetres: Double
    public var levels: Int?
    /// The `building` value (`house`, `yes`, …), or the `building:part` value for parts.
    public var kind: String
    public var isPart: Bool
    /// Linear-light colour from `roof:colour`, if tagged and understood.
    public var roofColour: SIMD3<Float>?
    /// Raw `roof:material` (e.g. `roof_tiles`, `metal`), if tagged.
    public var roofMaterial: String?
    /// Linear-light colour from `building:colour`, if tagged and understood.
    public var wallColour: SIMD3<Float>?
    /// The subset of OSM tags relevant to rendering (see `OSMParser.buildingTagKeys`).
    public var tags: [String: String]

    public init(id: Int64, footprint: [SIMD2<Double>], heightMetres: Double, minHeightMetres: Double = 0, levels: Int? = nil,
                kind: String = "yes", isPart: Bool = false, roofColour: SIMD3<Float>? = nil, roofMaterial: String? = nil,
                wallColour: SIMD3<Float>? = nil, tags: [String: String] = [:]) {
        self.id = id; self.footprint = footprint; self.heightMetres = heightMetres; self.minHeightMetres = minHeightMetres
        self.levels = levels; self.kind = kind; self.isPart = isPart; self.roofColour = roofColour
        self.roofMaterial = roofMaterial; self.wallColour = wallColour; self.tags = tags
    }

    /// Footprint area in m² (positive: the ring is counter-clockwise).
    public var area: Double { OSMGeometry.signedArea(footprint) }
}

/// Road classes drawn as ribbons (`highway=*`); footways, paths and cycleways are not.
public enum OSMHighway: String, Sendable, CaseIterable, Equatable {
    case motorway, motorwayLink = "motorway_link", trunk, trunkLink = "trunk_link"
    case primary, primaryLink = "primary_link", secondary, secondaryLink = "secondary_link"
    case tertiary, tertiaryLink = "tertiary_link", unclassified, residential, livingStreet = "living_street"
    case service, track

    public var isLink: Bool { rawValue.hasSuffix("_link") }

    /// Lanes assumed when `lanes` is not tagged (a dual carriageway is two oneway ways).
    public var defaultLanes: Int {
        switch self {
        case .motorwayLink, .trunkLink, .primaryLink, .secondaryLink, .tertiaryLink, .service, .track: return 1
        default: return 2
        }
    }

    public var laneWidth: Double {
        switch self {
        case .motorway, .motorwayLink, .trunk, .trunkLink: return 3.6
        case .primary, .primaryLink: return 3.5
        case .secondary, .secondaryLink: return 3.25
        case .tertiary, .tertiaryLink, .service: return 3.0
        case .unclassified, .residential, .livingStreet: return 2.75
        case .track: return 2.5
        }
    }

    /// Paved shoulders added to the lanes (both sides together).
    public var shoulders: Double {
        switch self {
        case .motorway, .trunk: return 3.0
        case .motorwayLink, .trunkLink: return 1.5
        case .primary, .secondary: return 1.0
        default: return 0
        }
    }
}

/// A road centreline from a `highway=*` way.
public struct OSMRoad: Sendable, Equatable {
    public var id: Int64
    /// Local metres (x east, y north), in way order, consecutive duplicates removed.
    public var points: [SIMD2<Double>]
    public var highway: OSMHighway
    public var lanes: Int?
    /// Paved width: the `width` tag, else lanes × lane width (+ shoulders) for the class.
    public var widthMetres: Double
    public var surface: String?
    public var tags: [String: String]

    public init(id: Int64, points: [SIMD2<Double>], highway: OSMHighway, lanes: Int? = nil, widthMetres: Double? = nil,
                surface: String? = nil, tags: [String: String] = [:]) {
        self.id = id; self.points = points; self.highway = highway; self.lanes = lanes
        self.widthMetres = widthMetres ?? OSMRoad.estimatedWidth(highway, lanes: lanes)
        self.surface = surface; self.tags = tags
    }

    public static func estimatedWidth(_ highway: OSMHighway, lanes: Int?) -> Double {
        let n = max(1, lanes ?? highway.defaultLanes)
        return Double(n) * highway.laneWidth + highway.shoulders
    }

    public var isTunnel: Bool { if let t = tags["tunnel"] { return t != "no" } else { return false } }
    public var isUnpaved: Bool {
        if highway == .track && surface == nil { return true }
        guard let s = surface else { return false }
        return ["unpaved", "dirt", "earth", "ground", "gravel", "fine_gravel", "compacted", "grass", "sand", "mud"].contains(s)
    }
}

/// Buildings and roads of one region, in local metres around the region's `GeoOrigin`.
public struct OSMData: Sendable, Equatable {
    public static let attribution = "Buildings and roads: © OpenStreetMap contributors, ODbL 1.0"
    public var buildings: [OSMBuilding]
    public var roads: [OSMRoad]
    public init(buildings: [OSMBuilding] = [], roads: [OSMRoad] = []) { self.buildings = buildings; self.roads = roads }
}

// MARK: - Geometry helpers

public enum OSMGeometry {
    @inline(__always) static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }

    /// Shoelace area: positive for counter-clockwise rings (x east, y north).
    public static func signedArea(_ ring: [SIMD2<Double>]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var s = 0.0
        for i in ring.indices { s += cross(ring[i], ring[(i + 1) % ring.count]) }
        return s / 2
    }

    /// Even-odd point-in-polygon test (points exactly on an edge may go either way).
    public static func contains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Area-weighted centroid (vertex mean for degenerate rings).
    public static func centroid(_ ring: [SIMD2<Double>]) -> SIMD2<Double> {
        let a = signedArea(ring)
        guard abs(a) > 1e-9 else { return ring.reduce(.zero, +) / Double(max(1, ring.count)) }
        var c = SIMD2<Double>.zero
        for i in ring.indices {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            c += (p + q) * cross(p, q)
        }
        return c / (6 * a)
    }

    /// Ear-clipping triangulation of a simple polygon given in either winding. Returns index
    /// triples into `polygon`, each counter-clockwise (x east, y north). Repeated and collinear
    /// vertices are tolerated; a self-intersecting input still yields triangles rather than hanging.
    public static func triangulate(_ polygon: [SIMD2<Double>]) -> [SIMD3<Int>] {
        // Drop consecutive duplicates (including a repeated closing point).
        var ring: [Int] = []
        for i in polygon.indices where ring.last.map({ polygon[$0] != polygon[i] }) ?? true { ring.append(i) }
        while ring.count > 1, polygon[ring[0]] == polygon[ring[ring.count - 1]] { ring.removeLast() }
        guard ring.count >= 3 else { return [] }
        if signedArea(ring.map { polygon[$0] }) < 0 { ring.reverse() }

        var lo = polygon[ring[0]], hi = lo
        for i in ring { lo = SIMD2(min(lo.x, polygon[i].x), min(lo.y, polygon[i].y)); hi = SIMD2(max(hi.x, polygon[i].x), max(hi.y, polygon[i].y)) }
        let span = max(hi.x - lo.x, hi.y - lo.y)
        let eps = 1e-10 * span * span

        let n = ring.count
        var next = (0..<n).map { ($0 + 1) % n }, prev = (0..<n).map { ($0 + n - 1) % n }
        func p(_ k: Int) -> SIMD2<Double> { polygon[ring[k]] }
        func turn(_ k: Int) -> Double { cross(p(k) - p(prev[k]), p(next[k]) - p(k)) }
        func remove(_ k: Int) { next[prev[k]] = next[k]; prev[next[k]] = prev[k] }
        func isEar(_ k: Int) -> Bool {
            let a = p(prev[k]), b = p(k), c = p(next[k])
            var j = next[next[k]]
            while j != prev[k] {
                let q = p(j)
                if q != a && q != b && q != c && turn(j) <= eps,   // only reflex/flat vertices can poke into an ear
                   cross(b - a, q - a) >= -eps, cross(c - b, q - b) >= -eps, cross(a - c, q - c) >= -eps { return false }
                j = next[j]
            }
            return true
        }

        var tris: [SIMD3<Int>] = []
        tris.reserveCapacity(n - 2)
        var remaining = n, k = 0, stop = 0
        while remaining > 3 {
            let t = turn(k)
            if abs(t) <= eps {
                // Collinear vertex or zero-width spike: removing it loses no area.
                let nk = next[k]; remove(k); remaining -= 1; k = prev[nk]; stop = k
                continue
            }
            if t > 0 && isEar(k) {
                tris.append(SIMD3(ring[prev[k]], ring[k], ring[next[k]]))
                let nk = next[k]; remove(k); remaining -= 1; k = nk; stop = k
                continue
            }
            k = next[k]
            if k == stop {
                // A full lap without an ear: not simple (or numerically ambiguous). Clip the most
                // convex vertex so the loop always terminates.
                var best = k, bestTurn = -Double.infinity, j = k
                repeat { let tj = turn(j); if tj > bestTurn { bestTurn = tj; best = j }; j = next[j] } while j != k
                if bestTurn > eps { tris.append(SIMD3(ring[prev[best]], ring[best], ring[next[best]])) }
                let nb = next[best]; remove(best); remaining -= 1; k = nb; stop = k
            }
        }
        if cross(p(k) - p(prev[k]), p(next[k]) - p(k)) > eps { tris.append(SIMD3(ring[prev[k]], ring[k], ring[next[k]])) }
        return tris
    }
}

// MARK: - Parsing

public enum OSMParser {
    public enum ParseError: Error, Equatable { case invalidJSON(String) }

    public static let buildingTagKeys: Set<String> = [
        "building", "building:part", "height", "min_height", "building:levels", "building:min_level", "roof:levels",
        "roof:shape", "roof:colour", "roof:material", "building:colour", "building:material", "name", "aeroway", "amenity",
    ]
    public static let roadTagKeys: Set<String> = ["highway", "lanes", "width", "surface", "name", "ref", "oneway", "bridge", "tunnel", "layer"]

    struct Response: Decodable { var elements: [Element]; var remark: String? }
    struct Element: Decodable {
        var type: String
        var id: Int64
        var tags: [String: String]?
        var geometry: [LatLon?]?
        var members: [Member]?
    }
    struct Member: Decodable { var type: String; var role: String?; var geometry: [LatLon?]? }
    struct LatLon: Decodable { var lat: Double; var lon: Double }

    /// The `remark` Overpass adds on timeouts and other runtime errors (the elements may be partial).
    public static func remark(_ data: Data) -> String? { (try? JSONDecoder().decode(Response.self, from: data))?.remark }

    /// Whether `data` is an Overpass JSON document (not an HTML error or rate-limit page).
    public static func isOverpassJSON(_ data: Data) -> Bool { (try? JSONDecoder().decode(Response.self, from: data)) != nil }

    /// Parses Overpass `[out:json]` / `out geom` output into local metres around `origin`.
    public static func parse(_ data: Data, origin: GeoOrigin) throws -> OSMData {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) } catch { throw ParseError.invalidJSON(String(describing: error)) }
        var buildings: [OSMBuilding] = [], roads: [OSMRoad] = []
        func local(_ g: [LatLon?]) -> [SIMD2<Double>] {
            g.compactMap { $0 }.map { let l = origin.local(latitude: $0.lat, longitude: $0.lon); return SIMD2(l.east, l.north) }
        }
        for e in response.elements {
            guard let tags = e.tags else { continue }
            switch e.type {
            case "way":
                guard let g = e.geometry else { continue }
                if let b = building(id: e.id, ring: local(g), tags: tags) { buildings.append(b) }
                else if let r = road(id: e.id, line: local(g), tags: tags) { roads.append(r) }
            case "relation" where tags["type"] == "multipolygon":
                // Outer rings that are closed in a single member; inner rings (courtyards) are ignored.
                for m in e.members ?? [] where m.type == "way" && (m.role ?? "outer") == "outer" {
                    guard let g = m.geometry, let first = g.first ?? nil, let last = g.last ?? nil,
                          first.lat == last.lat && first.lon == last.lon else { continue }
                    if let b = building(id: e.id, ring: local(g), tags: tags) { buildings.append(b) }
                }
            default: continue
            }
        }
        return OSMData(buildings: dropOutlinesWithParts(buildings), roads: roads)
    }

    /// Simple 3D Buildings: an outline that contains `building:part`s is not drawn itself.
    static func dropOutlinesWithParts(_ buildings: [OSMBuilding]) -> [OSMBuilding] {
        let parts = buildings.filter(\.isPart).map { OSMGeometry.centroid($0.footprint) }
        guard !parts.isEmpty else { return buildings }
        return buildings.filter { b in b.isPart || !parts.contains { OSMGeometry.contains(b.footprint, $0) } }
    }

    /// A CCW footprint without the closing duplicate, or nil when degenerate (< 3 distinct points or < 4 m²).
    public static func footprint(_ raw: [SIMD2<Double>]) -> [SIMD2<Double>]? {
        var ring: [SIMD2<Double>] = []
        for p in raw where ring.last.map({ simdLength(p - $0) > 0.01 }) ?? true { ring.append(p) }
        while ring.count > 1, simdLength(ring[0] - ring[ring.count - 1]) <= 0.01 { ring.removeLast() }
        var distinct: [SIMD2<Double>] = []
        for p in ring where !distinct.contains(where: { simdLength($0 - p) <= 0.01 }) { distinct.append(p); if distinct.count >= 3 { break } }
        guard distinct.count >= 3 else { return nil }
        let a = OSMGeometry.signedArea(ring)
        guard abs(a) >= 4 else { return nil }
        return a < 0 ? ring.reversed() : ring
    }

    static func building(id: Int64, ring raw: [SIMD2<Double>], tags: [String: String]) -> OSMBuilding? {
        let kindTag = tags["building"].flatMap { $0 == "no" ? nil : $0 }
        let partTag = tags["building:part"].flatMap { $0 == "no" ? nil : $0 }
        guard kindTag != nil || partTag != nil, let ring = footprint(raw) else { return nil }
        let isPart = kindTag == nil
        let kind = kindTag ?? partTag ?? "yes"
        let levels = tags["building:levels"].flatMap(parseNumber).map { Int($0.rounded()) }
        let minHeight = tags["min_height"].flatMap(parseLength) ?? tags["building:min_level"].flatMap(parseNumber).map { $0 * 3.0 } ?? 0
        var h = height(tags: tags, kind: kind)
        if h <= minHeight { h = minHeight + 3 }
        return OSMBuilding(id: id, footprint: ring, heightMetres: h, minHeightMetres: max(0, minHeight), levels: levels, kind: kind,
                           isPart: isPart, roofColour: tags["roof:colour"].flatMap(parseColour), roofMaterial: tags["roof:material"],
                           wallColour: tags["building:colour"].flatMap(parseColour), tags: tags.filter { buildingTagKeys.contains($0.key) })
    }

    /// `height`, else `building:levels` × 3.0 m + 1.0 m, else a default by building type.
    public static func height(tags: [String: String], kind: String) -> Double {
        if let h = tags["height"].flatMap(parseLength), h > 0 { return h }
        if let l = tags["building:levels"].flatMap(parseNumber), l > 0 { return l * 3.0 + 1.0 }
        return defaultHeight(kind: kind)
    }

    public static func defaultHeight(kind: String) -> Double {
        switch kind {
        case "house", "detached", "semidetached_house", "terrace", "bungalow": return 6.5
        case "residential", "apartments": return 12
        case "commercial", "retail": return 8
        case "industrial", "warehouse": return 9
        case "hangar": return 12
        default: return 7
        }
    }

    static func road(id: Int64, line raw: [SIMD2<Double>], tags: [String: String]) -> OSMRoad? {
        guard let cls = tags["highway"].flatMap(OSMHighway.init(rawValue:)) else { return nil }
        var pts: [SIMD2<Double>] = []
        for p in raw where pts.last.map({ simdLength(p - $0) > 0.01 }) ?? true { pts.append(p) }
        guard pts.count >= 2 else { return nil }
        let lanes = tags["lanes"].flatMap(parseNumber).map { max(1, Int($0.rounded())) }
        let width = tags["width"].flatMap(parseLength).flatMap { $0 > 0.5 && $0 < 100 ? $0 : nil }
        return OSMRoad(id: id, points: pts, highway: cls, lanes: lanes, widthMetres: width, surface: tags["surface"],
                       tags: tags.filter { roadTagKeys.contains($0.key) })
    }

    /// A plain number ("3", "2.5", "12,5"); the first value of a `;` list.
    public static func parseNumber(_ s: String) -> Double? {
        let t = s.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return Double(t.contains(".") ? t : t.replacingOccurrences(of: ",", with: "."))
    }

    /// Lengths in metres: "12", "12.5", "12 m", "12m", "12 metres", "40 ft", "40'", "6'6\"", "1.2 km".
    public static func parseLength(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let semi = t.firstIndex(of: ";") { t = String(t[..<semi]).trimmingCharacters(in: .whitespaces) }
        if !t.contains(".") { t = t.replacingOccurrences(of: ",", with: ".") }
        let numChars = Set("0123456789.-+")
        let numEnd = t.firstIndex { !numChars.contains($0) } ?? t.endIndex
        guard let value = Double(t[..<numEnd]), value.isFinite else { return nil }
        let unit = t[numEnd...].trimmingCharacters(in: .whitespaces)
        switch unit {
        case "", "m", "meter", "meters", "metre", "metres": return value
        case "ft", "feet", "foot": return value * 0.3048
        case "km": return value * 1000
        case "mi": return value * 1609.344
        default:
            // Feet and inches: 6' or 6'6" (the number before the apostrophe is already in `value`).
            guard unit.hasPrefix("'") || unit.hasPrefix("’") else { return nil }
            let rest = unit.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "\"” "))
            let inches = rest.isEmpty ? 0 : Double(rest)
            guard let inches else { return nil }
            return (value * 12 + inches) * 0.0254
        }
    }

    /// `#rgb` / `#rrggbb` or a common colour name (sRGB) → linear-light, slightly muted so
    /// saturated tag values do not glow.
    public static func parseColour(_ s: String) -> SIMD3<Float>? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        var rgb: (Int, Int, Int)?
        if t.hasPrefix("#") {
            let hex = Array(t.dropFirst())
            func v(_ c: ArraySlice<Character>) -> Int? { Int(String(c), radix: 16) }
            if hex.count == 6, let r = v(hex[0..<2]), let g = v(hex[2..<4]), let b = v(hex[4..<6]) { rgb = (r, g, b) }
            else if hex.count == 3, let r = v(hex[0..<1]), let g = v(hex[1..<2]), let b = v(hex[2..<3]) { rgb = (r * 17, g * 17, b * 17) }
        } else {
            rgb = namedColours[t]
        }
        guard let (r, g, b) = rgb else { return nil }
        let c = srgb(r, g, b)
        let lum = (c * SIMD3<Float>(0.2126, 0.7152, 0.0722)).sum()
        return (c * 0.75 + SIMD3(repeating: lum) * 0.25) * 0.85
    }

    static let namedColours: [String: (Int, Int, Int)] = [
        "white": (255, 255, 255), "black": (0, 0, 0), "grey": (128, 128, 128), "gray": (128, 128, 128),
        "darkgrey": (90, 90, 90), "darkgray": (90, 90, 90), "lightgrey": (211, 211, 211), "lightgray": (211, 211, 211),
        "silver": (192, 192, 192), "red": (180, 40, 30), "darkred": (139, 0, 0), "maroon": (128, 0, 0),
        "brown": (125, 75, 45), "orange": (230, 140, 40), "yellow": (240, 220, 90), "beige": (225, 215, 185),
        "tan": (210, 180, 140), "cream": (240, 230, 200), "green": (60, 110, 60), "darkgreen": (30, 70, 35),
        "blue": (50, 80, 150), "lightblue": (160, 190, 215), "navy": (20, 30, 80), "terracotta": (180, 90, 60),
        "pink": (230, 170, 170), "sand": (215, 195, 150), "olive": (128, 128, 0), "teal": (0, 128, 128),
    ]
}

// MARK: - Overpass query

/// Overpass QL for buildings and drawable highways in a lat/lon box, rounded outward to 1e-3°
/// so the cache key and the request always describe the same area.
public struct OverpassQuery: Sendable, Equatable {
    public static let defaultEndpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    public let south: Double, west: Double, north: Double, east: Double
    public var endpoint: URL

    public init(south: Double, west: Double, north: Double, east: Double, endpoint: URL = OverpassQuery.defaultEndpoint) {
        func down(_ v: Double) -> Double { (v * 1000).rounded(.down) / 1000 }
        func up(_ v: Double) -> Double { (v * 1000).rounded(.up) / 1000 }
        self.south = down(min(south, north)); self.north = up(max(south, north))
        self.west = down(min(west, east)); self.east = up(max(west, east))
        self.endpoint = endpoint
    }

    /// A box covering ±`halfExtent` metres east and north of `origin`.
    public init(origin: GeoOrigin, halfExtent: Double, endpoint: URL = OverpassQuery.defaultEndpoint) {
        let corners = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { origin.coordinate(east: $0.0 * halfExtent, north: $0.1 * halfExtent) }
        self.init(south: corners.map(\.latitude).min()!, west: corners.map(\.longitude).min()!,
                  north: corners.map(\.latitude).max()!, east: corners.map(\.longitude).max()!, endpoint: endpoint)
    }

    static func fmt(_ v: Double) -> String { String(format: "%.3f", v == 0 ? 0 : v) }
    var bbox: String { "\(Self.fmt(south)),\(Self.fmt(west)),\(Self.fmt(north)),\(Self.fmt(east))" }

    public var cacheKey: String { "osm/\(bbox)" }

    public var ql: String {
        let classes = OSMHighway.allCases.map(\.rawValue).joined(separator: "|")
        return """
        [out:json][timeout:60];
        (
          way["building"](\(bbox));
          way["building:part"](\(bbox));
          relation["building"]["type"="multipolygon"](\(bbox));
          way["highway"~"^(\(classes))$"](\(bbox));
        );
        out geom;
        """
    }

    /// `<endpoint>?data=<percent-encoded QL>` (only RFC 3986 unreserved characters left bare).
    public var url: URL {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        let encoded = ql.addingPercentEncoding(withAllowedCharacters: allowed)!
        return URL(string: endpoint.absoluteString + "?data=" + encoded)!
    }
}

// MARK: - Service

/// Fetches OSM buildings/roads once per box and keeps the raw JSON in the content store.
/// Cached data is served without touching the network (OSM changes slowly); `refresh` forces a
/// fetch and falls back to the cache when it fails. Offline with nothing cached → nil.
public actor OSMService {
    public enum Source: String, Sendable { case memory, disk, network }
    private let transport: any HTTPTransport
    private let cache: KeyedCache?
    private let endpoint: URL
    private var memory: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]
    public private(set) var networkRequests = 0
    public private(set) var lastSource: Source?

    public init(transport: any HTTPTransport, cache: KeyedCache?, endpoint: URL = OverpassQuery.defaultEndpoint) {
        self.transport = transport; self.cache = cache; self.endpoint = endpoint
    }

    /// Buildings and roads within ±`halfExtent` m of `origin`, in metres around that origin.
    public func data(around origin: GeoOrigin, halfExtent: Double, refresh: Bool = false) async -> OSMData? {
        await data(for: OverpassQuery(origin: origin, halfExtent: halfExtent, endpoint: endpoint), origin: origin, refresh: refresh)
    }

    public func data(for query: OverpassQuery, origin: GeoOrigin, refresh: Bool = false) async -> OSMData? {
        guard let raw = await rawJSON(for: query, refresh: refresh) else { return nil }
        return try? OSMParser.parse(raw, origin: origin)
    }

    /// The raw Overpass JSON for a query (memory → disk → network, or network first with `refresh`).
    public func rawJSON(for query: OverpassQuery, refresh: Bool = false) async -> Data? {
        let key = query.cacheKey
        if !refresh, let local = await stored(key) { return local }
        if let fresh = await fetch(query) {
            memory[key] = fresh
            lastSource = .network
            return fresh
        }
        return refresh ? await stored(key) : nil
    }

    private func stored(_ key: String) async -> Data? {
        if let m = memory[key] { lastSource = .memory; return m }
        if let cache, let d = await cache.get(key), OSMParser.isOverpassJSON(d) {
            memory[key] = d
            lastSource = .disk
            return d
        }
        return nil
    }

    /// One request per box at a time. Only well-formed, complete responses are cached; a
    /// partial result (Overpass runtime-error remark) is returned for this flight but not kept.
    private func fetch(_ query: OverpassQuery) async -> Data? {
        let key = query.cacheKey
        if let task = inFlight[key] { return await task.value }
        let url = query.url, transport = self.transport
        networkRequests += 1
        let task = Task<Data?, Never> {
            guard let data = try? await transport.get(url), OSMParser.isOverpassJSON(data) else { return nil }
            return data
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data, let cache, OSMParser.remark(data).map({ !$0.lowercased().contains("error") }) ?? true {
            try? await cache.put(key, data)
        }
        return data
    }
}

// MARK: - Meshes

/// Linux-testable triangle soups for OSM features (origin .zero, local metres, z up, CCW from outside).
public enum OSMMeshBuilder {
    public static let wallPalette: [SIMD3<Float>] = [
        srgb(200, 192, 176), srgb(186, 178, 164), srgb(210, 204, 192), srgb(176, 160, 140),
        srgb(160, 128, 108), srgb(178, 178, 172), srgb(196, 184, 160), srgb(150, 140, 128),
    ]
    public static let industrialWalls: [SIMD3<Float>] = [srgb(184, 182, 176), srgb(170, 172, 170), srgb(196, 194, 188)]
    public static let roofGrey = srgb(128, 128, 124), roofDark = srgb(72, 72, 74), roofTerracotta = srgb(156, 82, 58)
    public static let roofLight = srgb(168, 168, 162)

    static func seed(_ b: OSMBuilding) -> UInt64 {
        let p = b.footprint.first ?? .zero
        return Hash.int(Int((p.x * 10).rounded()), Int((p.y * 10).rounded()), seed: 0x05B1_D1A6)
    }

    static func isHouseLike(_ kind: String) -> Bool {
        ["house", "detached", "semidetached_house", "terrace", "bungalow", "residential", "farm", "cabin", "garage", "shed"].contains(kind)
    }
    static func isIndustrial(_ kind: String) -> Bool { ["industrial", "warehouse", "hangar", "factory", "manufacture"].contains(kind) }

    /// Deterministic wall colour: the tagged `building:colour`, else the muted palette by a hash of the first vertex.
    public static func wallColour(for b: OSMBuilding) -> SIMD3<Float> {
        if let c = b.wallColour { return c }
        let h = seed(b)
        let palette = isIndustrial(b.kind) ? industrialWalls : wallPalette
        return palette[Int(h % UInt64(palette.count))] * Float(0.92 + 0.14 * Hash.unit(Hash.mix(h)))
    }

    /// Roof colour: tagged `roof:colour`, else from `roof:material`, else grey/dark/terracotta by type and hash.
    public static func roofColour(for b: OSMBuilding) -> SIMD3<Float> {
        if let c = b.roofColour { return c }
        switch b.roofMaterial {
        case "roof_tiles", "tile", "tiles", "clay": return roofTerracotta
        case "slate": return srgb(78, 82, 88)
        case "metal", "metal_sheet", "eternit": return srgb(160, 163, 165)
        case "concrete", "gravel", "stone": return srgb(146, 144, 138)
        case "tar_paper", "asphalt", "asphalt_shingle", "bitumen": return roofDark
        case "glass": return srgb(92, 110, 120)
        case "wood", "thatch": return srgb(120, 96, 72)
        case "grass", "plants": return srgb(88, 108, 62)
        case "copper": return srgb(104, 140, 120)
        default: break
        }
        let h = Hash.mix(seed(b) ^ 0x2F)
        if isIndustrial(b.kind) || b.area > 600 { return [roofLight, roofGrey][Int(h % 2)] }
        if isHouseLike(b.kind) { return [roofTerracotta, roofDark, roofGrey, roofTerracotta * 0.85][Int(h % 4)] }
        return [roofGrey, roofDark, roofLight][Int(h % 3)]
    }

    /// Minimum ground height under a footprint: vertices, points every ≤ 10 m along the edges and the centroid.
    public static func baseHeight(_ footprint: [SIMD2<Double>], ground: (Double, Double) -> Double) -> Double {
        var lo = Double.infinity
        for i in footprint.indices {
            let a = footprint[i], b = footprint[(i + 1) % footprint.count]
            let steps = max(1, Int((simdLength(b - a) / 10).rounded(.up)))
            for s in 0..<steps { let p = a + (b - a) * (Double(s) / Double(steps)); lo = min(lo, ground(p.x, p.y)) }
        }
        let c = OSMGeometry.centroid(footprint)
        if OSMGeometry.contains(footprint, c) { lo = min(lo, ground(c.x, c.y)) }
        return lo.isFinite ? lo : 0
    }

    /// Extruded buildings with flat ear-clipped roofs. Walls stand on the minimum ground height
    /// under each footprint and reach `foundation` metres below it (hiding terrain-mesh
    /// interpolation gaps); parts with `min_height` float and get an underside instead.
    public static func buildings(_ buildings: [OSMBuilding], foundation: Double = 1.0, ground: (Double, Double) -> Double) -> TriangleSoup {
        var soup = TriangleSoup(origin: .zero)
        for b in buildings {
            var ring = b.footprint
            if OSMGeometry.signedArea(ring) < 0 { ring.reverse() }
            guard ring.count >= 3 else { continue }
            let base = baseHeight(ring, ground: ground)
            let top = base + b.heightMetres
            let bottom = b.minHeightMetres > 0 ? base + b.minHeightMetres : base - max(0, foundation)
            guard top > bottom else { continue }
            let wall = wallColour(for: b), roof = roofColour(for: b)
            for i in ring.indices {
                let p = ring[i], q = ring[(i + 1) % ring.count]
                soup.addQuad(SIMD3(p.x, p.y, bottom), SIMD3(q.x, q.y, bottom), SIMD3(q.x, q.y, top), SIMD3(p.x, p.y, top),
                             colour: wall, material: .opaque)
            }
            let tris = OSMGeometry.triangulate(ring)
            if b.minHeightMetres <= 0, let hip = hippedRoof(b, ring: ring) {
                // Ridge along the long axis; the sunlit and shaded slopes give a small house its volume
                // from approach height, where a flat lid reads as a box.
                let rise = hip.short / 2 * tan(30 * Double.pi / 180)
                let rA = SIMD3(hip.ridgeA.x, hip.ridgeA.y, top + rise), rB = SIMD3(hip.ridgeB.x, hip.ridgeB.y, top + rise)
                func v(_ i: Int) -> SIMD3<Double> { let p = ring[(i + hip.first) % 4]; return SIMD3(p.x, p.y, top) }
                let ridged = simdLength(hip.ridgeB - hip.ridgeA) > 0.05   // a square house gets a pyramid
                soup.addFlat(v(0), v(1), rB, colour: roof, material: .opaque)
                if ridged { soup.addFlat(v(0), rB, rA, colour: roof, material: .opaque) }
                soup.addFlat(v(1), v(2), rB, colour: roof, material: .opaque)
                soup.addFlat(v(2), v(3), rA, colour: roof, material: .opaque)
                if ridged { soup.addFlat(v(2), rA, rB, colour: roof, material: .opaque) }
                soup.addFlat(v(3), v(0), rA, colour: roof, material: .opaque)
            } else {
                for t in tris {
                    let a = ring[t.x], c1 = ring[t.y], c2 = ring[t.z]
                    soup.addFlat(SIMD3(a.x, a.y, top), SIMD3(c1.x, c1.y, top), SIMD3(c2.x, c2.y, top), colour: roof, material: .opaque)
                }
            }
            if b.minHeightMetres > 0 {
                for t in tris {
                    let a = ring[t.x], c1 = ring[t.y], c2 = ring[t.z]
                    soup.addFlat(SIMD3(a.x, a.y, bottom), SIMD3(c2.x, c2.y, bottom), SIMD3(c1.x, c1.y, bottom), colour: wall * 0.7, material: .opaque)
                }
            }
        }
        return soup
    }

    /// Hipped-roof layout for a small four-cornered house (counter-clockwise `ring`): `first` is the corner
    /// that starts a long edge, the ridge runs between `ridgeA` (near edge first+3→first) and `ridgeB`
    /// (near edge first+1→first+2), inset half the short side from each end. Nil for other buildings:
    /// tagged flat roofs, more or fewer than four corners, footprints over 400 m² or not roughly rectangular.
    static func hippedRoof(_ b: OSMBuilding, ring: [SIMD2<Double>]) -> (first: Int, ridgeA: SIMD2<Double>, ridgeB: SIMD2<Double>, short: Double)? {
        guard ring.count == 4 else { return nil }
        let shape = b.tags["roof:shape"]
        if let shape, shape != "hipped" && shape != "gabled" { return nil }
        let houseLike: Set<String> = ["house", "detached", "semidetached_house", "residential", "bungalow", "farm", "cabin", "terrace"]
        guard shape != nil || houseLike.contains(b.kind) else { return nil }
        guard abs(OSMGeometry.signedArea(ring)) <= 400 else { return nil }
        func len(_ i: Int) -> Double { simdLength(ring[(i + 1) % 4] - ring[i]) }
        // Roughly rectangular: opposite edges within 25 % of each other.
        guard abs(len(0) - len(2)) < 0.25 * max(len(0), len(2)), abs(len(1) - len(3)) < 0.25 * max(len(1), len(3)) else { return nil }
        let first = (len(0) + len(2)) >= (len(1) + len(3)) ? 0 : 1
        let long = (len(first) + len(first + 2)) / 2, short = (len(first + 1) + len(first + 3)) / 2
        guard short > 1 else { return nil }
        let c = ring.reduce(.zero, +) / 4
        let p = { (i: Int) in ring[(i + first) % 4] }
        let axis = simdNormalize((p(1) + p(2)) / 2 - (p(3) + p(0)) / 2)
        let half = max(0, long - short) / 2
        return (first, c - axis * half, c + axis * half, short)
    }

    public static func roadColour(for r: OSMRoad) -> SIMD3<Float> {
        if r.isUnpaved { return srgb(122, 106, 84) }
        switch r.highway {
        case .motorway, .motorwayLink, .trunk, .trunkLink: return srgb(58, 58, 60)
        case .service: return srgb(80, 80, 80)
        case .track: return srgb(96, 92, 86)
        default: return srgb(68, 68, 70)
        }
    }

    /// Terrain-draped ribbons (material `.road`) `lift` metres above `ground`, resampled every
    /// ≤ `maxSegment` metres, mitred at bends (miter length capped at 2× half-width). Tunnels are skipped.
    public static func roads(_ roads: [OSMRoad], lift: Double = 0.3, maxSegment: Double = 20,
                             ground: (Double, Double) -> Double) -> TriangleSoup {
        var soup = TriangleSoup(origin: .zero)
        for r in roads where !r.isTunnel && r.points.count >= 2 {
            var pts: [SIMD2<Double>] = [r.points[0]]
            for i in 1..<r.points.count {
                let a = pts[pts.count - 1], b = r.points[i]
                let len = simdLength(b - a)
                guard len > 0.01 else { continue }
                let n = max(1, Int((len / max(1, maxSegment)).rounded(.up)))
                for s in 1...n { pts.append(a + (b - a) * (Double(s) / Double(n))) }
            }
            guard pts.count >= 2 else { continue }
            let half = r.widthMetres / 2
            var left: [SIMD3<Double>] = [], right: [SIMD3<Double>] = []
            for i in pts.indices {
                func normal(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> { let d = simdNormalize(b - a); return SIMD2(-d.y, d.x) }
                let nIn = i > 0 ? normal(pts[i - 1], pts[i]) : nil
                let nOut = i < pts.count - 1 ? normal(pts[i], pts[i + 1]) : nil
                var off: SIMD2<Double>
                switch (nIn, nOut) {
                case let (a?, b?):
                    let m = a + b
                    let ml = simdLength(m)
                    if ml < 1e-6 { off = a * half }   // hairpin reversal
                    else { let mn = m / ml; off = mn * (half / max(0.5, (mn * a).sum())) }
                case let (a?, nil): off = a * half
                case let (nil, b?): off = b * half
                default: off = .zero
                }
                let l = pts[i] + off, rr = pts[i] - off
                left.append(SIMD3(l.x, l.y, ground(l.x, l.y) + lift))
                right.append(SIMD3(rr.x, rr.y, ground(rr.x, rr.y) + lift))
            }
            let colour = roadColour(for: r)
            for i in 0..<(pts.count - 1) {
                soup.addQuad(right[i], right[i + 1], left[i + 1], left[i], colour: colour, material: .road)
            }
        }
        return soup
    }
}

@inline(__always) func simdLength(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
@inline(__always) func simdNormalize(_ v: SIMD2<Double>) -> SIMD2<Double> { let l = simdLength(v); return l > 0 ? v / l : .zero }
