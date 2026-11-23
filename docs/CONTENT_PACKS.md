# Content packs: getting from 0.2 GB to about 15 GB of real content

Goal: about 15 GB of visible, real quality content (high-resolution terrain and imagery for more regions and airports, detailed ground and building textures, aircraft liveries, audio, open-world and mission data). Everything stays free and openly licensed. Building footprints stay OpenStreetMap-only (`docs/DECISIONS.md`). Attribution goes in `THIRD_PARTY_NOTICES.md` and the in-app list.

This document is the plan for milestone 1. No pack data is added in this PR.

## Current state

- The app bundles about 196 MB of scenery under `Packages/SkyforgeKit/Sources/SFQuickFlight/Resources/Showcase/` (six airports). Git holds it all.
- `docs/MASTER_PROMPT.md` section 9.7 caps the app bundle at 150 MB and says large content is downloaded, not bundled.
- Optional curated packs use Apple-hosted Background Assets. They need a manual App Store Connect upload. On-Demand Resources are not used.
- The app downloads content only from sources that allow prefetch, and first-launch downloads need an in-app disclosure and consent (Guideline 4.2.3).

## Measured source sizes (checked 2026-11-23)

| Source | Measured | Use |
|---|---|---|
| LINZ Queenstown 2021, 0.1 m, `nz-imagery` bucket | 998 tiles listed (first page is complete), 28.3 GB of GeoTIFF source | Sharp NZQN imagery. Source is large, but the pack stores JPEG tiles, so pack size is set by zoom and area, not by source size. |
| Copernicus DEM GLO-30, 1° tile (`copernicus-dem-30m`) | about 42.5 MB per tile before compression | Higher-resolution terrain for showcase regions and the "anywhere" work (`WORLD_STREAMING_PLAN.md` M2). |
| ESA WorldCover 10 m 2021 v200 | reachable, about 1 KB per range read | Land cover for procedural fallback (M4). |
| Overture buildings and roads (OSM-only filter) | reachable | More building footprints, for the airports and regions in the manifest. |

## Pack plan

Packs are per region, in four kinds. Each is built and checked on its own.

1. **terrain**: Copernicus GLO-30 converted to the app's DEM format, at the region's extent.
2. **imagery**: Web Mercator JPEG pyramid, per region. Zoom and area set the size.
3. **surface**: WorldCover land cover, plus OSM roads, buildings and airport surfaces (already produced by existing tools).
4. **textures and audio**: ground and building texture sets and sound banks. Made in later milestones, not here.

A pack has a manifest with the source, licence, attribution string, SHA-256 and byte size of every file. The app refuses any file whose hash does not match.

Initial budget (to be measured when each pack is built, not estimated now):

| Pack | Target size | Milestone |
|---|---|---|
| NZQN sharp imagery (Queenstown, z17 to z19) | 4.5 GB | M2 |
| Terrain at 30 m for the six showcase airports and their ±40 km regions | 1.5 GB | M2 |
| More airports with sharp imagery and terrain (Sentinel-2 at 10 m where no sharper source exists) | 3.5 GB | M3 |
| Ground and building textures, detail maps | 2.5 GB | M4 |
| Aircraft liveries and cockpit textures (fleet) | 1.5 GB | M4 |
| Audio (engines, wind, cabin, ATC voices where licensed) | 1.0 GB | M4 |
| Missions, traffic and open-world data | 0.5 GB | M5 |

The 15 GB target is set by Pranav (2026-11-23). Visuals and gameplay come first, so imagery, terrain, textures, aircraft and audio take most of the budget. Pack slots are coordinated with the new missions, aircraft fleet, audio and hi-res region threads.

## Pipeline (to build)

1. `content/packs.json` lists each pack: region, kinds, zoom levels, sources, and attribution.
2. `tools/build_content_pack.py --plan` reads the list and prints the planned sizes and the sources it will fetch. It makes no downloads.
3. `tools/build_content_pack.py --pack <id> --out build/packs/<id>` fetches the sources through the existing `tools/fetch_*.py` modules, writes the files, and writes `pack.json` with hashes and sizes.
4. `tools/check_content_packs.py` fails if a hash does not match, if the attribution is missing, or if a host is not in `docs/DATA_SOURCES.md`.
5. CI runs the planner and the check on every PR. The full build runs only on a manual workflow, because it is slow and uses bandwidth.

## Delivery

- The app reads packs from Background Assets. Each pack is a separate asset pack, downloaded on first use, with a disclosure and consent before any download.
- The base install stays under 150 MB.
- Uploads to App Store Connect are manual (about 5 GB per release). A helper prints the file list for the upload.
- Local and CI builds read packs from `build/packs/`, so the app can be tested without the store.

## Milestones

- **M1 (this PR): plan.** This document only.
- **M2: pipeline and NZQN pack.** `packs.json`, `build_content_pack.py`, `check_content_packs.py`, and the first real pack (NZQN imagery and terrain), with hashes and attribution in `THIRD_PARTY_NOTICES.md`. Test: the check passes on CI, and the pack size is recorded in the PR.
- **M3: Background Assets wiring.** A small `SFContent` loader for packs, with consent, hash verification and tests for interrupted and corrupt downloads. Uses the storage rules in `MASTER_PROMPT.md` section 9.7.
- **M4: more regions and textures.** Adds packs for more airports and the texture and audio sets.
- **M5: size and soak.** Total pack size near 5 GB, the base install still under 150 MB, and a flight test that loads each pack on device.

## Coordination

- Visuals threads: the pack formats must match their loaders (`LINZAerialProvider`, `RoadPack`, `AirportPack`, `LandUsePack`).
- "Fly anywhere on Earth" streaming thread: owns the region hand-off. Packs feed it, not the other way round.
- GPU perf thread: owns `WorldRenderer` changes. Pack loading stays out of the renderer.

## Decisions needed

- **Hosting for packs.** Apple-hosted Background Assets is the documented path (fits the App Store limits, needs a manual upload each release). The alternative is self-hosted release files. That needs a new download path and a new source in `DATA_SOURCES.md`, and it changes the first-launch download rule.
