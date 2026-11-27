# Halden Reach: original open-world design

Status: v1 design (worldgenVersion 1). Map: `docs/worlds/halden-reach/map.svg`. Data contract: `docs/worlds/halden-reach/world.json`. Generator: `tools/world_map/make_world.py`.

## 1. Pitch
Halden Reach is a handcrafted island the size of a small country, made for flying. You can cross it in 25 minutes at cruise, and every region has a reason to fly to it: a hub city, a coastline, mountain strips, lakes, and bush country. It is the second world option next to the real Earth (SkyWorld), and it is fully original, so it has no licensing or data-source constraints beyond the project's rules (open source, OSM-only where real data is used).

## 2. Scale and frame
- Island footprint: about 130 x 95 km, inside a 140 x 100 km frame.
- Coordinates: local metres, x east, y north, origin at the frame's south-west corner. The JSON stores km; the generator converts to metres.
- Highest peak: Mount Ardent, 2,870 m. Sea level is 0 m.
- Chunking follows the existing generator: 1 km chunks, deterministic per `(seed, cx, cy)`, `worldgenVersion` bumped on any output change.

## 3. Geography
- **Coastline:** a 17-point polygon with a deep bay on the east side (Serrin Bay) and a cliffed west coast near Brightwater.
- **Mountains:** one main ridge runs south-west to north-east from Harrow Crest to Greywether. Five named peaks sit on it. The west side is gentler, so approach from the coast works. Mountain flying is the main terrain challenge.
- **Rivers:** Tessel River (widest, 180 m, reaches the bay at Tessel Falls) and Orra River (90 m, reaches the south coast).
- **Lake Ysolde:** a freshwater lake with a seaplane base, in the middle of the island.

## 4. Regions and biomes
| Region | Biome | Character |
|---|---|---|
| Ashwold Steppe | dry grassland | open, flat, long sight lines, dirt strips |
| Serrin Coast | coastal farmland | fields, dunes, port industry |
| Caldera Plain | temperate farmland | patchwork fields, dense road network |
| Ardent Highlands | alpine conifer | steep valleys, snow above 2,000 m, mountain strips |
| Northern Woods | mixed forest | dense trees, small towns, lakes |
| Brightwater Downs | wet heath | low hills, mist, coastal fog |

Biomes set vegetation density, ground colour, and the seasonal palette. They do not change the flight model.

## 5. Settlements
Tiers: hub, city, town, village. Population affects building count and landmark rules. Names and positions are fixed in `world.json` so the planner can be tested against them.

- **Caldera:** hub city, 320k people, with the main international airport.
- **Port Serrin:** 110k, port and regional airport.
- **Northgate:** 60k, northern city with a regional field.
- **Brightwater:** 45k, west coast city with a GA strip.
- **Towns:** Ashwold, Millbrook, Tessel Falls, Greyhaven, Kestrel Cross.
- **Village:** Saltmarsh.

## 6. Airports
Codes use the `HR` prefix, so they never clash with real ICAO codes.

| Code | Name | Class | Runway | Surface | Elevation |
|---|---|---|---|---|---|
| HRCI | Caldera International | hub | 3,600 m | asphalt | 40 m |
| HRPS | Port Serrin Regional | regional | 1,800 m | asphalt | 15 m |
| HRNG | Northgate Field | regional | 1,400 m | asphalt | 210 m |
| HRBW | Brightwater Strip | GA | 900 m | asphalt | 60 m |
| HRKX | Kestrel Cross Field | GA | 1,000 m | grass | 90 m |
| HRAH | Ashwold Hangar Strip | bush | 700 m | dirt | 480 m |
| HRTS | Tessel Strip | bush | 500 m | grass | 35 m |
| HRKT | Kestrel Tor | bush | 620 m | gravel | 1,120 m |
| HRAR | Ardent Rest | mountain | 800 m | gravel | 1,900 m |
| HRYS | Lake Ysolde Water Base | seaplane | 1,200 m water | water | 180 m |

Every airport needs a runway flattened by the terrain recipe, the same way existing airfields are.

## 7. Roads and transport
- **Coast Highway:** runs along the south and east coast, linking Brightwater, Northgate and Port Serrin.
- **Caldera Expressway:** links Caldera with Port Serrin and Millbrook.
- **Ridge Road:** a secondary arterial over the central pass toward Ardent Rest.
- Rivers have no bridges in v1. Roads cross at the named crossings only.

## 8. Flying in Halden Reach
- Routes: coast-to-coast VFR, valley runs in the highlands, and seaplane runs across Lake Ysolde.
- The mountain strips (HRAR, HRKT) need the mountain procedures from the flight-school and bush threads.
- Weather and time-of-day follow the existing presets. Each region can override the default wind.

## 9. Build plan (milestones, one PR each)
1. **Design and map (this PR):** this doc, the world JSON, the SVG map, and the generator.
2. **Data loader:** a Swift `OriginalWorld` type in `SFWorldGen` that reads the same numbers as `world.json`. Adds a unit test that the loaded airports, cities and island match the JSON.
3. **Terrain recipe:** a `TerrainKind.halden` recipe built from the island, ridges, rivers and lake. Uses the existing `flattenZones` for airports.
4. **Selectable world:** a world picker in the app shell. Halden Reach sits next to SkyWorld (real Earth).
5. **Settlements and airports:** driven by the sibling "cities and airports" thread's `OpenWorldPlanner`. It takes this doc's positions, density and naming rules.

Each milestone must pass CI. The cloud has no Swift toolchain, so CI is the build check.

## 10. Rules for the sibling threads
- **Terrain thread:** keep the island polygon and ridge positions. Heights come from the recipe, but the coast and ridge must match the JSON within 2 km.
- **Cities and airports thread:** use the positions, populations and airport classes in `world.json` as fixed anchors. Add detail around them, but do not move them.
- **Naming:** use only names in this doc or new names that follow the same style (short, English-like, no real places).
- **Density:** towns and villages fill the gaps. Keep the hub city as the densest area in the world.
- **Licensing:** everything is original and open source. Do not add data from non-OSM sources.

## 11. Open questions
- Exact stage-3 height target at each peak (current values are design targets, not measured).
- Whether HRYS should count as a regional airport for ATC.
