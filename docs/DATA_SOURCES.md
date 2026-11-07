# Data sources

Every network host the app (or tooling) contacts must be listed here. `tools/check_licenses.py` enforces this for URLs in `Sources/`.

| Source | Host(s) | Licence | Attribution shown in app | Status |
|---|---|---|---|---|
| AWS Terrain Tiles (Terrarium) | s3.amazonaws.com (`elevation-tiles-prod`) | Mixed open sources, see tilezen/joerd docs/attribution.md | Per-source list from joerd attribution | Planned P1 |
| Copernicus DEM GLO-30/90 | copernicus-dem-30m / -90m on AWS Open Data | Copernicus licence (free redistribution) | "produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved" | Planned P3 (COG reader) |
| OurAirports | davidmegginson.github.io | Public Domain | "Airport data courtesy of OurAirports" | Planned P1 |
| aviationweather.gov Data API | aviationweather.gov | US government (public domain) | "Weather: NOAA/NWS Aviation Weather Center" | Planned P1 |
| Open-Meteo | api.open-meteo.com | CC BY 4.0 (one sub-repository states CC BY-NC 4.0; conflict noted, app is non-commercial either way) | "Weather data by Open-Meteo.com" | Planned P2 |
| OpenStreetMap via Overpass | overpass-api.de | ODbL | "© OpenStreetMap contributors, ODbL" | Planned P3 (verify Overpass policy first) |
| EOX Sentinel-2 cloudless 2016 | tiles.maps.eox.at | CC BY 4.0 (2016 layer only) | "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016 & 2017)" | Optional, off by default, P3+ |

Tooling hosts (not used by the app): download.swift.org, swift.org, github.com (toolchain and SwiftPM).

Excluded: tile.openstreetmap.org, vector.openstreetmap.org, Google Photorealistic 3D Tiles, Cesium ion, Bing/Apple/Mapbox imagery, Microsoft assets, Navigraph, OpenAIP, live OpenSky.

Test fixture: `Packages/SkyforgeKit/Tests/Fixtures/terrarium/rainier_10_165_360.png` (AWS Terrain Tiles, Terrarium tile 10/165/360, Mount Rainier; fetched 2026-11-07; attribution per tilezen/joerd docs/attribution.md, USGS NED/SRTM sources in this area).
Test fixture: `Packages/SkyforgeKit/Tests/Fixtures/metar/metars.txt`: 230 real METAR reports recorded 2026-11-07 from the aviationweather.gov Data API (NOAA/NWS Aviation Weather Center, US government work, public domain), selected for coverage (CAVOK, gusts, VRB, variable sectors, RVR, vertical visibility, inHg/hPa, fractional SM, negative temperatures, TS/SN/FG, MPS, SPECI, missing fields).
