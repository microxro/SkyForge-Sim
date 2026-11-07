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
