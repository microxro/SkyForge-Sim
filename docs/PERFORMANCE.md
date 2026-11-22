# Performance

Targets are in docs/MASTER_PROMPT.md §11. Only measured numbers go here; nothing has been measured on a device yet.

| Tier | Device | Frame time p50 / p99 | Hitches/min | GPU ms | Memory | Source |
|---|---|---|---|---|---|---|
| — | — | not measurable in this sandbox (no Metal device) | — | — | — | — |

## Frame-time targets (documented; device numbers unverified)

| Tier | Target | Frame budget | Status |
|---|---|---|---|
| High | 60 fps | 16.67 ms | CI Metal frame-time test within budget (VERIFICATION_LOG); no device run yet |
| Low | 30 fps | 33.3 ms | CI Metal frame-time test within budget; no device run yet |

Pacing: p99 frame time <= 1.25x target, at most 1 hitch (> 2x target) per minute in steady cruise (MASTER_PROMPT section 11). Nothing here is measured on iPhone or iPad hardware; treat device fps as unverified until run on a device.

## Quick Flight mesh budgets (measured 2026-11-08, `sfpreview quickflight-stats`, 4-core Linux release build)
| Tier | Triangles | Vertex memory (20 B/vertex, non-indexed) | CPU build time |
|---|---|---|---|
| phone (`DeviceTier.low`) | 703,433 | 40 MB | 5.1 s |
| tablet (`.medium`) | 1,628,124 | 93 MB | 9.0 s |
| desktop (`.high`/`.ultra`) | 2,585,967 | 148 MB | 13.8 s |
Notes: the mesh is static and non-indexed; shadows re-draw it twice per frame. Next steps for frame time on phones: indexed terrain grids, chunked frustum culling, impostor trees beyond 600 m, and shadow casters limited to the cascade boxes. Frame times on devices are not measured yet (no device; CI runs only offscreen correctness tests).
