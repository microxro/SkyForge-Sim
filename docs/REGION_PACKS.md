# Region packs (high-detail famous regions)

Status: milestone 1 (manifest, validator, budget). No imagery, elevation or building data is fetched yet.

## What a region pack is
A downloadable, offline region: one bounding box (at most 1.5° × 1.5°) with imagery, elevation, OSM
buildings and original landmark models, shipped as a tile pack (see `TilePack`, ADR-0015) through Apple
Background Assets. The manifest is `tools/region_packs/regions.json`; `validate_regions.py` runs in CI.

## Planned regions (15.0 GB total, estimates)
| Region | Imagery (licence) | Target GB |
|---|---|---|
| nyc-manhattan (city skyline) | USGS orthoimagery (public domain, 0.5 m) | 3.0 |
| grand-canyon-south-rim | USGS orthoimagery (public domain, 0.5 m) | 2.0 |
| alps-engadin | Sentinel-2 cloudless (CC BY 4.0, 10 m) | 3.0 |
| hawaii-big-island | Sentinel-2 cloudless (CC BY 4.0, 10 m) | 2.0 |
| norway-geirangerfjord | Sentinel-2 cloudless (CC BY 4.0, 10 m) | 2.5 |
| nz-mount-cook | LINZ aerial (CC BY 4.0, 0.3 m) | 2.5 |

Elevation is AWS Terrarium DEM for every region. Buildings are OpenStreetMap only (ODbL, user decision).
Landmark models are original work (Apache-2.0). Sizes are planning numbers, not measurements.

## Build environment limits (probed 2026-11-23 from the cloud session)
| Host | Result | Needed for |
|---|---|---|
| overpass-api.de, api.openstreetmap.org | unreachable (000) | OSM buildings, roads |
| basemap.nationalmap.gov (USGS) | unreachable | USGS orthoimagery |
| services.sentinel-hub.com, dataspace.copernicus.eu | unreachable | Sentinel-2 |
| data.opentopography.org | unreachable | alternative DEM |
| elevation-tiles-prod.s3.amazonaws.com | reachable (200) | Terrarium DEM |

Consequence: the cloud session cannot fetch the 15 GB. Builds need a machine that can reach the
hosts above, with about 20 GB of free disk per region. Imagery and buildings are the blockers, not code.

## Milestones
1. Manifest, validator and CI gate (this PR).
2. Builder: `tools/region_packs/build_region.py` that writes a `TilePack` per region, reusing `fetch_buildings.py` and `fetch_linz_imagery.py`. Needs a host that reaches OSM and the imagery services.
3. Background Assets delivery: one asset pack per region, with size checked against the manifest.
4. Landmark models and lighting, one region per PR.

## Licence rules
- Only free, openly licensed data, with attribution shown in Settings → Attributions.
- Sources must be listed in `docs/DATA_SOURCES.md` before any region uses them.
- No Overture or other ML-derived footprints (ADR-0016, user decision).
