// SKYFORGE — Apache-2.0
// Airports, runways and navaids from OurAirports (public domain).
import Foundation
import SFMath

public struct RunwayEnd: Sendable, Equatable {
    public var ident: String
    public var position: Geodetic?           // threshold (nil when the source has no coordinates)
    public var elevationFeet: Double?
    public var headingTrueDegrees: Double?
    public var displacedThresholdFeet: Double
}

public struct Runway: Sendable, Equatable {
    public var airportIdent: String
    public var lengthFeet: Double
    public var widthFeet: Double
    public var surface: String
    public var lighted: Bool
    public var closed: Bool
    public var low: RunwayEnd
    public var high: RunwayEnd

    public var lengthMetres: Double { lengthFeet * Units.feetToMetres }
    public var widthMetres: Double { widthFeet * Units.feetToMetres }
    /// True when both thresholds have coordinates (runway geometry can be generated).
    public var hasGeometry: Bool { low.position != nil && high.position != nil }

    /// Geodesic heading from the low end to the high end (true degrees), from the coordinates.
    public var computedHeadingDegrees: Double? {
        guard let a = low.position, let b = high.position else { return nil }
        return Geodesic.inverse(a, b).initialBearing * Units.radToDeg
    }
    /// Distance between thresholds (m).
    public var thresholdSeparationMetres: Double? {
        guard let a = low.position, let b = high.position else { return nil }
        return Geodesic.inverse(a, b).distance
    }

    /// Hard surfaces (asphalt/concrete variants) as used for synthetic ILS eligibility.
    public var isHardSurface: Bool {
        let s = surface.uppercased()
        return ["ASP", "CON", "PEM", "BIT", "ASPH", "CONC"].contains { s.hasPrefix($0) }
    }
}

public struct Airport: Sendable, Equatable {
    public var ident: String
    public var type: String
    public var name: String
    public var position: Geodetic
    public var elevationFeet: Double?
    public var country: String
    public var municipality: String
    public var iataCode: String
}

public enum NavaidType: String, Sendable {
    case vor = "VOR", vorDme = "VOR-DME", vortac = "VORTAC", dme = "DME", ndb = "NDB", ndbDme = "NDB-DME", tacan = "TACAN", other
}

public struct Navaid: Sendable, Equatable {
    public var ident: String
    public var name: String
    public var type: NavaidType
    public var frequencyKHz: Double
    public var position: Geodetic
    public var dmePosition: Geodetic?
    public var associatedAirport: String
    /// VOR/VORTAC frequency in MHz (navaids file stores kHz).
    public var frequencyMHz: Double { frequencyKHz / 1000 }
}

/// Synthetic ILS generated for long hard runways (OurAirports has no reliable ILS data). Always labelled.
public struct SyntheticILS: Sendable, Equatable {
    public var runwayIdent: String
    public var threshold: Geodetic
    public var courseTrueDegrees: Double
    public var glideslopeDegrees: Double
    public var thresholdCrossingHeightFeet: Double
    public let isSynthetic = true
    public var label: String { "Synthetic ILS \(runwayIdent) (not real-world data)" }
}

public struct NavDatabase: Sendable {
    public private(set) var airports: [String: Airport] = [:]
    public private(set) var runwaysByAirport: [String: [Runway]] = [:]
    public private(set) var navaids: [Navaid] = []

    public init() {}

    public init(airportsCSV: String, runwaysCSV: String, navaidsCSV: String) {
        for r in CSV.records(airportsCSV) {
            guard let ident = r["ident"], !ident.isEmpty,
                  let lat = Double(r["latitude_deg"] ?? ""), let lon = Double(r["longitude_deg"] ?? "") else { continue }
            let elev = Double(r["elevation_ft"] ?? "")
            airports[ident] = Airport(ident: ident, type: r["type"] ?? "", name: r["name"] ?? "",
                                      position: Geodetic(latitudeDegrees: lat, longitudeDegrees: lon, height: (elev ?? 0) * Units.feetToMetres),
                                      elevationFeet: elev, country: r["iso_country"] ?? "", municipality: r["municipality"] ?? "",
                                      iataCode: r["iata_code"] ?? "")
        }
        for r in CSV.records(runwaysCSV) {
            guard let ident = r["airport_ident"], !ident.isEmpty else { continue }
            func end(_ p: String) -> RunwayEnd {
                let lat = Double(r["\(p)_latitude_deg"] ?? ""), lon = Double(r["\(p)_longitude_deg"] ?? "")
                let elev = Double(r["\(p)_elevation_ft"] ?? "")
                let pos = (lat != nil && lon != nil) ? Geodetic(latitudeDegrees: lat!, longitudeDegrees: lon!, height: (elev ?? 0) * Units.feetToMetres) : nil
                return RunwayEnd(ident: r["\(p)_ident"] ?? "", position: pos, elevationFeet: elev,
                                 headingTrueDegrees: Double(r["\(p)_heading_degT"] ?? ""),
                                 displacedThresholdFeet: Double(r["\(p)_displaced_threshold_ft"] ?? "") ?? 0)
            }
            let rw = Runway(airportIdent: ident, lengthFeet: Double(r["length_ft"] ?? "") ?? 0, widthFeet: Double(r["width_ft"] ?? "") ?? 0,
                            surface: r["surface"] ?? "", lighted: r["lighted"] == "1", closed: r["closed"] == "1",
                            low: end("le"), high: end("he"))
            runwaysByAirport[ident, default: []].append(rw)
        }
        for r in CSV.records(navaidsCSV) {
            guard let ident = r["ident"], let lat = Double(r["latitude_deg"] ?? ""), let lon = Double(r["longitude_deg"] ?? "") else { continue }
            let elev = (Double(r["elevation_ft"] ?? "") ?? 0) * Units.feetToMetres
            var dme: Geodetic?
            if let dl = Double(r["dme_latitude_deg"] ?? ""), let dn = Double(r["dme_longitude_deg"] ?? "") {
                dme = Geodetic(latitudeDegrees: dl, longitudeDegrees: dn, height: elev)
            }
            navaids.append(Navaid(ident: ident, name: r["name"] ?? "", type: NavaidType(rawValue: r["type"] ?? "") ?? .other,
                                  frequencyKHz: Double(r["frequency_khz"] ?? "") ?? 0,
                                  position: Geodetic(latitudeDegrees: lat, longitudeDegrees: lon, height: elev),
                                  dmePosition: dme, associatedAirport: r["associated_airport"] ?? ""))
        }
    }

    public func airport(_ ident: String) -> Airport? { airports[ident] }
    public func runways(at ident: String) -> [Runway] { runwaysByAirport[ident] ?? [] }
    public func navaids(ident: String) -> [Navaid] { navaids.filter { $0.ident == ident } }

    /// Nearest airport with at least one runway that has geometry (for Quick Flight).
    public func nearestAirportWithRunwayGeometry(to p: Geodetic) -> Airport? {
        airports.values
            .filter { runways(at: $0.ident).contains(where: \.hasGeometry) }
            .min { Geodesic.inverse(p, $0.position).distance < Geodesic.inverse(p, $1.position).distance }
    }

    /// Synthetic 3° ILS for each hard, open runway end of at least 1,200 m with coordinates.
    public func syntheticILS(at ident: String) -> [SyntheticILS] {
        var out: [SyntheticILS] = []
        for rw in runways(at: ident) where rw.hasGeometry && !rw.closed && rw.lengthMetres >= 1_200 && rw.isHardSurface {
            guard let lo = rw.low.position, let hi = rw.high.position else { continue }
            let inv = Geodesic.inverse(lo, hi)
            out.append(SyntheticILS(runwayIdent: rw.low.ident, threshold: lo, courseTrueDegrees: inv.initialBearing * Units.radToDeg,
                                    glideslopeDegrees: 3, thresholdCrossingHeightFeet: 50))
            out.append(SyntheticILS(runwayIdent: rw.high.ident, threshold: hi,
                                    courseTrueDegrees: Geodesic.normalizeAngle(inv.finalBearing + .pi) * Units.radToDeg,
                                    glideslopeDegrees: 3, thresholdCrossingHeightFeet: 50))
        }
        return out
    }

    /// Bearing (true degrees) and distance (NM) from a position to a navaid's DME (or the navaid).
    public static func bearingDistance(from p: Geodetic, to n: Navaid) -> (bearingTrue: Double, distanceNM: Double) {
        let target = n.dmePosition ?? n.position
        let inv = Geodesic.inverse(p, target)
        return (inv.initialBearing * Units.radToDeg, inv.distance / Units.nmToMetres)
    }

    /// OurAirports file URL (public domain; listed in docs/DATA_SOURCES.md).
    public static func ourAirportsURL(_ file: String) -> String { "https://davidmegginson.github.io/ourairports-data/\(file).csv" }
}
