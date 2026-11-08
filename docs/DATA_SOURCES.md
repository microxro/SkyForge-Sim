# Data sources

Every network host the app (or tooling) contacts must be listed here. `tools/check_licenses.py` enforces this for URLs in `Sources/`.

| Source | Host(s) | Licence | Attribution shown in app | Status |
|---|---|---|---|---|
| AWS Terrain Tiles (Terrarium) | s3.amazonaws.com (`elevation-tiles-prod`) | Mixed open sources, see tilezen/joerd docs/attribution.md | Per-source list from joerd attribution | Planned P1 |
| Copernicus DEM GLO-30/90 | copernicus-dem-30m / -90m on AWS Open Data | Copernicus licence (free redistribution) | "produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved" | Planned P3 (COG reader) |
| OurAirports | davidmegginson.github.io | Public Domain | "Airport data courtesy of OurAirports" | Planned P1 |
| aviationweather.gov Data API | aviationweather.gov | US government (public domain) | "Weather: NOAA/NWS Aviation Weather Center" | In use (P1.7b): `METARService`, `GET /api/data/metar?ids=<ICAO>&format=raw`, no key; 10-min cache, stale-on-failure |
| Open-Meteo | api.open-meteo.com | CC BY 4.0 (one sub-repository states CC BY-NC 4.0; conflict noted, app is non-commercial either way) | "Weather data by Open-Meteo.com" | Planned P2 |
| OpenStreetMap via Overpass | overpass-api.de | ODbL | "© OpenStreetMap contributors, ODbL" | Planned P3 (verify Overpass policy first) |
| EOX Sentinel-2 cloudless 2016 | tiles.maps.eox.at | CC BY 4.0 (2016 layer only) | "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017)" | Optional, off by default, P3+ |

Tooling hosts (not used by the app): download.swift.org, swift.org, github.com (toolchain and SwiftPM).

Excluded: tile.openstreetmap.org, vector.openstreetmap.org, Google Photorealistic 3D Tiles, Cesium ion, Bing/Apple/Mapbox imagery, Microsoft assets, Navigraph, OpenAIP, live OpenSky.

Test fixture: `Packages/SkyforgeKit/Tests/Fixtures/terrarium/rainier_10_165_360.png` (AWS Terrain Tiles, Terrarium tile 10/165/360, Mount Rainier; fetched 2026-11-07; attribution per tilezen/joerd docs/attribution.md, USGS NED/SRTM sources in this area).
Test fixture: `Packages/SkyforgeKit/Tests/Fixtures/metar/metars.txt`: 230 real METAR reports recorded 2026-11-07 from the aviationweather.gov Data API (NOAA/NWS Aviation Weather Center, US government work, public domain), selected for coverage (CAVOK, gusts, VRB, variable sectors, RVR, vertical visibility, inHg/hPa, fractional SM, negative temperatures, TS/SN/FG, MPS, SPECI, missing fields).
Test fixture: `Packages/SkyforgeKit/Tests/Fixtures/ourairports/{airports,runways,navaids}.csv`: OurAirports rows (public domain) for KSFO, KOAK, EGLL, LFPG, RJTT, 00A, 0GA2 (name with a comma) and AR-0767 (non-ASCII name), fetched 2026-11-07.
Bundled data: `Packages/SkyforgeKit/Sources/SFNavData/Resources/{airports,runways,navaids}.csv.z` + `manifest.json`: OurAirports snapshot built 2026-11-07 by `tools/make_airport_snapshot.py` (closed airports, heliports and balloonports removed; 49,345 airports, 35,379 runways, 11,008 navaids; 2.6 MB compressed). Shown in app as "Airport data courtesy of OurAirports (public domain)".
Bundled data: `Packages/SkyforgeKit/Sources/SFTerrainCore/Resources/global_dem.sfdem` (+ `global_dem.json` with SHA-256): offline global elevation baseline, 4096 x 2048 equirectangular (~5.3 arc-minutes), built 2026-11-07 by `tools/make_global_dem.py` from AWS Terrain Tiles Terrarium zoom 4 (256 tiles); 29 isolated artefact pixels despiked; 11.7 MB. Attribution per tilezen/joerd docs/attribution.md (SRTM, GMTED2010, ETOPO1, NED and others). Latitudes beyond ±85.05° are clamped to the nearest Web Mercator row.

## Orthoimagery (P1.13, real-world ground)
| Source | Host | Licence | Attribution shown in app | Status |
|---|---|---|---|---|
| USGS The National Map, USGSImageryOnly (USDA NAIP and other orthoimagery), US only | basemap.nationalmap.gov | US Government work, public domain | "Imagery: USGS The National Map / USDA NAIP (public domain)" | In use (`USGSImageryProvider`, z ≤ 16) |
| EOX Sentinel-2 cloudless **2016** edition, worldwide | tiles.maps.eox.at (`s2cloudless_3857`) | CC BY 4.0 (stated in the WMTS capabilities). Later editions (2017+) are CC BY-NC-SA and are NOT used. | "Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data 2016), CC BY 4.0" | In use (`Sentinel2CloudlessProvider`, z ≤ 14) |
Test fixtures: `Tests/Fixtures/imagery/usgs_15_13676_9038.jpg` (public domain) and `s2c2016_10_284_435.jpg` (CC BY 4.0, attribution above), each with a Pillow-decoded `.pillow.rgb` reference.
