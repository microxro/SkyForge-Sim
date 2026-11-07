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
