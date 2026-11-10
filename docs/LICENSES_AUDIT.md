# Licence audit

| Candidate | Licence (verified from LICENSE file) | Last commit checked | Decision |
|---|---|---|---|
| apple/swift-crypto | Apache-2.0 (LICENSE.txt fetched 2026-11-07) | resolved 4.5.2 on 2026-11-07 | Allowed; only SwiftPM dependency |
| apple/swift-asn1 | Apache-2.0 | resolved 1.7.4 | Allowed (transitive) |
| JSBSim | LGPL-2.1 | not vendored | Offline oracle only, never shipped |
| FlightGear / YASim | GPL | — | Excluded |
| libnoise | LGPL | — | Excluded; own noise in SFMath |
| OpenAL Soft | LGPL | — | Excluded; AVAudioEngine |

Every further dependency gets a row with the licence file and last-commit date checked before vendoring (§14).

## Audit 2026-11-10 (after #3, main 4648b6e)
- **`tools/check_licenses.py`: OK.** Every SwiftPM dependency is in THIRD_PARTY_NOTICES.md, every network host in Sources is in DATA_SOURCES.md, and there is no GPL, LGPL or AGPL text in Sources.
- **SwiftPM dependencies:** unchanged since 2026-11-07 (swift-crypto and swift-asn1, Apache-2.0). New code since then (`ImageryDelighting`, forest stands, the cloud tent) is our own.
- **Excluded sources:** no Microsoft, Bing, VirtualEarth, MSFS, Google Maps, Mapbox or Esri references in Sources, App or the docs (case-insensitive scan; the only hits were substrings such as "describing" and "climbing").
- **Bundled showcase packs** (6 airports, 1,724 tiles), every tile URL by host:

  | Host | Tiles | Licence |
  |---|---|---|
  | basemap.nationalmap.gov | 1,233 | USGS NAIP, public domain |
  | tiles.maps.eox.at (`s2cloudless_3857`, the 2016 edition) | 293 | CC BY 4.0; the 2017+ editions are CC BY-NC-SA and are not used |
  | s3.amazonaws.com/elevation-tiles-prod/terrarium | 198 | AWS open data; Mapzen/Tilezen terms, attributed |

  Each manifest carries the matching attribution lines (USGS, EOX Sentinel-2 cloudless 2016, Terrarium, OurAirports).
- **Result:** clean. Apache-2.0 compatible, keyless, free sources only.
