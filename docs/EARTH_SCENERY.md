# Whole-Earth scenery download

The optional, free whole-Earth scenery is a separate download. The base game stays at 3.8 GB (3 GB main story, 0.8 GB multiplayer systems). Delivery uses Apple Background Assets, one asset pack per segment.

## Catalog format (schema 1)

`scenery-catalog.json`, one per release:

```json
{
  "schema": 1,
  "release": "earth-2026.11",
  "segments": [
    { "id": "eu-west-z6", "bytes": 2000000000, "sha256": "<64 hex>",
      "bounds": { "minLat": 50, "maxLat": 60, "minLon": -10, "maxLon": 0 } }
  ],
  "attribution": ["Copernicus DEM GLO-30 (ESA, CC BY 4.0)"]
}
```

- Segment IDs are lowercase letters, digits and hyphens. The ID is also the Background Assets pack ID.
- Bounds are degrees. Segments never cross the antimeridian: split them.
- `SceneryCatalog.validated()` rejects anything else before a download starts.

## Engine (`Sources/SFContent/Scenery/`)

- `SceneryCatalog`: format, validation, totals.
- `ScenerySyncMachine`: install state (not installed, consent, downloading, paused, verifying, installed, failed). Illegal events are refused.
- `ScenerySpace` and `ScenerySpaceAdvisor`: quota 1–500 GB (default 10 GB) and a free-space reserve of max(5 GB, 10% of capacity).
- `ScenerySelection`: which segments are still missing.
- `ScenerySourceResolver`: installed segment, or procedural fallback. Flight never waits for the download.
- `ScenerySyncNetworkPolicy`: Wi-Fi only unless the player allows cellular.

## Not in this milestone

- Background Assets binding (needs the asset packs uploaded in App Store Connect and a downloader extension target, verified on Apple CI).
- Download and resume UI in `SFUI`.
- Renderer and gameplay integration (owned by the Earth integration thread and the renderer owner).
