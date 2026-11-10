# Third-party notices

## Software (linked into the app)

| Component | Version | Licence | Source | Notes |
|---|---|---|---|---|
| swift-crypto | 4.5.2 (range 3.0.0..<5.0.0) | Apache-2.0 | https://github.com/apple/swift-crypto | Used for SHA-256 content addressing. On Apple platforms it re-exports CryptoKit; on Linux it compiles vendored BoringSSL (OpenSSL/ISC-style licences, see the package's LICENSE files). |
| swift-asn1 | 1.7.4 (transitive) | Apache-2.0 | https://github.com/apple/swift-asn1 | Transitive dependency of swift-crypto. |

No GPL, LGPL or AGPL code is linked into the app.

## Tools (not shipped)

| Tool | Licence | Use |
|---|---|---|
| Python 3 standard library | PSF | PNG recompression and project lint scripts in `tools/` |
| JSBSim (planned, P1) | LGPL-2.1 | Offline validation oracle only, never shipped |

## Data

See `docs/DATA_SOURCES.md` for every data source, licence and the attribution text shown in the app.

## Data (not linked into the binary; fetched at runtime or used as test fixtures)
- Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data 2016). Licence: Creative Commons Attribution 4.0 International (https://creativecommons.org/licenses/by/4.0/).
- USGS The National Map orthoimagery (USDA NAIP): US public domain.
- OpenStreetMap building footprints and road centrelines for the showcase airports, as distributed in the Overture Maps buildings and transportation themes (records whose primary source is OpenStreetMap only). © OpenStreetMap contributors. Licence: Open Database Licence 1.0 (https://opendatacommons.org/licenses/odbl/1-0/). The bundled `buildings.sfb` and `roads.sfr` files are a derived database and stay under the ODbL.
- ESA WorldCover 2021 v200 (10 m land cover), © ESA WorldCover project, contains modified Copernicus Sentinel data. Licence: Creative Commons Attribution 4.0 International.
- Toitū Te Whenua Land Information New Zealand aerial imagery (Queenstown 2021 0.1 m; Otago 2017–2021 0.3 m), bundled for the Queenstown airport only. Licence: Creative Commons Attribution 4.0 International.
