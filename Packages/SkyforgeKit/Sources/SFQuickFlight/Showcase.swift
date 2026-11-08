// SKYFORGE — Apache-2.0
// Showcase airports: real-world Quick Flight starts whose imagery and elevation tiles ship in the
// app as tile packs (built by `sfpreview pack-airport`), so they fly offline. Any other airport in
// the bundled OurAirports data streams on first use and is cached.
import Foundation
import SFContent

public struct ShowcaseAirport: Sendable, Equatable, Hashable {
    public let ident: String
    public let name: String
    public let kind: String
    /// METAR stations for the live sky, nearest first.
    public let metarStations: [String]
}

public enum Showcase {
    public static let airports: [ShowcaseAirport] = [
        ShowcaseAirport(ident: "KMRY", name: "Monterey, California", kind: "US coast", metarStations: ["KMRY", "KSNS"]),
        ShowcaseAirport(ident: "KASE", name: "Aspen, Colorado", kind: "US mountains", metarStations: ["KASE", "KEGE"]),
        ShowcaseAirport(ident: "KBFI", name: "Boeing Field, Seattle", kind: "US city", metarStations: ["KBFI", "KSEA"]),
        ShowcaseAirport(ident: "LSZS", name: "Samedan, Switzerland", kind: "Alps (Sentinel-2)", metarStations: ["LSZS", "LSZA"]),
        ShowcaseAirport(ident: "NZQN", name: "Queenstown, New Zealand", kind: "Southern Alps (Sentinel-2)", metarStations: ["NZQN"]),
        ShowcaseAirport(ident: "KCOI", name: "Merritt Island, Florida", kind: "US coast", metarStations: ["KCOI", "KTIX", "KMLB"]),
    ]

    /// The default Quick Flight start.
    public static let defaultAirport = airports[0]

    /// The bundled pack for an airport, if the app ships one.
    public static func pack(for ident: String) -> TilePack? {
        guard let url = Bundle.module.url(forResource: ident, withExtension: nil, subdirectory: "Showcase") else { return nil }
        return try? TilePack(root: url)
    }

    /// Transport that serves bundled tiles for `ident` first and streams the rest (offline: `fallback` nil).
    public static func transport(for ident: String, fallback: (any HTTPTransport)?) -> any HTTPTransport {
        guard let p = pack(for: ident) else { return fallback ?? TilePackTransport(packs: [], fallback: nil) }
        return TilePackTransport(packs: [p], fallback: fallback)
    }
}
