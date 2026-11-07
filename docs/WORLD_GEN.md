# SkyWorld generation and art direction bible

Status: P0 skeleton. `SFWorldGenInfo.worldgenVersion = 1`.

## Art direction (from §8.0)
- Hero lighting: golden hour. Presets: sunrise, golden hour, midday, overcast, dusk, night, storm.
- Filmic ACES-style tonemap with a gentle S-curve, soft bloom, soft vignette, restrained saturation, warm key / cool shadow split.
- Regional palettes derived from seed and climate (warm brick, white stucco, grey concrete, timber, terracotta); no random rainbow colours.
- No identical neighbouring buildings; per-instance tint/scale/rotation jitter; landmarks placed by rule.
- Depth cues: aerial perspective, haze layers, cloud shadows, layered ridges, sun glitter, wet-road speculars.
- Release-blocking defects: z-fighting, shimmering, stretching, floating/intersecting objects, bad normals, LOD popping, visible tiling.

## Generator contract
Deterministic, chunked (1 km), budgeted (ms per chunk recorded), content-addressed cache, versioned by `worldgenVersion`, unit-tested (determinism hash, bounds, no overlaps, no NaN).
