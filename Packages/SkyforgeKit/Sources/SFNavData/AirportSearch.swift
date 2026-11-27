// SKYFORGE — Apache-2.0
// Worldwide airport search and nearest-airport queries over the bundled OurAirports data (public domain).
// Only airports with at least one open runway that has coordinates are returned: those are the ones
// Quick Flight can generate a real-imagery region for.
import Foundation
import SFMath

/// A search result: the airport, its flyable runway count and the relevance score that ranked it.
public struct AirportHit: Sendable, Equatable, Identifiable {
    public var id: String { airport.ident }
    public var airport: Airport
    public var flyableRunways: Int
    public var score: Int
}

/// An airport near a position, with the great-circle distance to it.
public struct NearbyAirport: Sendable, Equatable, Identifiable {
    public var id: String { airport.ident }
    public var airport: Airport
    public var flyableRunways: Int
    public var distanceMetres: Double
}

public enum AirportSearch {
    /// Larger airports rank first when relevance ties.
    public static func typeRank(_ type: String) -> Int {
        switch type {
        case "large_airport": return 3
        case "medium_airport": return 2
        case "small_airport", "seaplane_base": return 1
        default: return 0
        }
    }

    /// Open runways with coordinates at an airport (the count Quick Flight needs to fly from it).
    public static func flyableRunwayCount(_ db: NavDatabase, _ ident: String) -> Int {
        db.runways(at: ident).reduce(0) { $0 + (($1.hasGeometry && !$1.closed) ? 1 : 0) }
    }

    /// Ranked, case-insensitive search over ident, IATA code, name, municipality and country code.
    /// Match strength, best first: ident or IATA code equal (100), ident or IATA prefix (80), name prefix (70),
    /// a name word starting with the query (60), municipality prefix (55), name contains (40, three or more
    /// characters), municipality contains (35), country code equal (30). An empty query lists the largest flyable
    /// airports first. Ties go to the larger airport type, then to the ident.
    public static func search(_ query: String, in db: NavDatabase, limit: Int = 100) -> [AirportHit] {
        guard limit > 0 else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hits: [AirportHit] = []
        for apt in db.airports.values {
            let n = flyableRunwayCount(db, apt.ident)
            guard n > 0 else { continue }
            let s = q.isEmpty ? 10 + 10 * typeRank(apt.type) : score(apt, q)
            guard s > 0 else { continue }
            hits.append(AirportHit(airport: apt, flyableRunways: n, score: s))
        }
        hits.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let ra = typeRank(a.airport.type), rb = typeRank(b.airport.type)
            if ra != rb { return ra > rb }
            return a.airport.ident < b.airport.ident
        }
        return hits.count > limit ? Array(hits.prefix(limit)) : hits
    }

    /// Relevance of one airport for an already lower-cased, non-empty query (0 = no match).
    static func score(_ apt: Airport, _ q: String) -> Int {
        let ident = apt.ident.lowercased()
        let iata = apt.iataCode.lowercased()
        let name = apt.name.lowercased()
        let town = apt.municipality.lowercased()
        if ident == q || (!iata.isEmpty && iata == q) { return 100 }
        if ident.hasPrefix(q) || (!iata.isEmpty && iata.hasPrefix(q)) { return 80 }
        if name.hasPrefix(q) { return 70 }
        if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 60 }
        if !town.isEmpty && town.hasPrefix(q) { return 55 }
        if q.count >= 3 && name.contains(q) { return 40 }
        if q.count >= 3 && !town.isEmpty && town.contains(q) { return 35 }
        if q.count == 2 && apt.country.lowercased() == q { return 30 }
        return 0
    }

    /// Airports with a flyable runway, closest to `p` first.
    public static func nearest(to p: Geodetic, in db: NavDatabase, limit: Int = 20) -> [NearbyAirport] {
        guard limit > 0 else { return [] }
        var out: [NearbyAirport] = []
        for apt in db.airports.values {
            let n = flyableRunwayCount(db, apt.ident)
            guard n > 0 else { continue }
            out.append(NearbyAirport(airport: apt, flyableRunways: n,
                                     distanceMetres: Geodesic.inverse(p, apt.position).distance))
        }
        out.sort { a, b in
            if a.distanceMetres != b.distanceMetres { return a.distanceMetres < b.distanceMetres }
            return a.airport.ident < b.airport.ident
        }
        return out.count > limit ? Array(out.prefix(limit)) : out
    }
}
