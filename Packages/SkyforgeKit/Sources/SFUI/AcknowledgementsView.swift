// SKYFORGE — Apache-2.0
#if canImport(SwiftUI)
import SwiftUI

/// "Acknowledgements and Data Attribution". Required by the licences of the bundled and downloaded data
/// (ODbL 1.0, CC BY 4.0). Keep in step with `docs/DATA_SOURCES.md` and `THIRD_PARTY_NOTICES.md`.
public struct AcknowledgementsView: View {
    public init() {}

    private static let data: [(String, String)] = [
        ("Buildings and roads", "© OpenStreetMap contributors, ODbL 1.0, via Overture Maps Foundation."),
        ("Land cover", "© ESA WorldCover project 2021, contains modified Copernicus Sentinel data, CC BY 4.0."),
        ("Satellite imagery", "Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data 2016), CC BY 4.0."),
        ("US aerial imagery", "USGS The National Map / USDA NAIP (public domain)."),
        ("Queenstown aerial imagery", "Toitū Te Whenua Land Information New Zealand aerial imagery, CC BY 4.0."),
        ("Elevation", "AWS Terrain Tiles (Terrarium), built from SRTM, GMTED2010, ETOPO1, USGS NED and other open sources; see https://github.com/tilezen/joerd/blob/master/docs/attribution.md."),
        ("Airports", "Airport data courtesy of OurAirports (public domain)."),
        ("Weather", "NOAA/NWS Aviation Weather Center (public domain)."),
    ]

    private static let software: [(String, String)] = [
        ("SKYFORGE", "Copyright 2026 The SKYFORGE contributors. Apache License 2.0."),
        ("swift-crypto and swift-asn1", "Copyright Apple Inc. and the SwiftCrypto project authors. Apache License 2.0."),
    ]

    public var body: some View {
        List {
            Section {
                ForEach(Self.data, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.headline)
                        Text(item.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Data") }
            Section {
                ForEach(Self.software, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(.headline)
                        Text(item.1).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Software") } footer: {
                Text("SKYFORGE is free and open source. Source code and full licence texts: https://github.com/microxro/SkyForge-Sim")
            }
            Section {
                Text("SKYFORGE collects no personal data, has no accounts, and contains no analytics or tracking. Network requests fetch public map, elevation, airport and weather data only, directly from the providers listed here, which can see your IP address.")
                    .font(.footnote)
            } header: { Text("Privacy") }
        }
        .navigationTitle("Acknowledgements")
    }
}
#endif
