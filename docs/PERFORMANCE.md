# Performance

Targets are in docs/MASTER_PROMPT.md §11. Only measured numbers go here; nothing has been measured on a device yet.

| Tier | Device | Frame time p50 / p99 | Hitches/min | GPU ms | Memory | Source |
|---|---|---|---|---|---|---|
| — | — | not measurable in this sandbox (no Metal device) | — | — | — | — |

## Quick Flight mesh budgets (measured 2026-11-08, `sfpreview quickflight-stats`, 4-core Linux release build)
| Tier | Triangles | Vertex memory (20 B/vertex, non-indexed) | CPU build time |
|---|---|---|---|
| phone (`DeviceTier.low`) | 703,433 | 40 MB | 5.1 s |
| tablet (`.medium`) | 1,628,124 | 93 MB | 9.0 s |
| desktop (`.high`/`.ultra`) | 2,585,967 | 148 MB | 13.8 s |
Notes: the mesh is static and non-indexed; shadows re-draw it twice per frame. Next steps for frame time on phones: indexed terrain grids, chunked frustum culling, impostor trees beyond 600 m, and shadow casters limited to the cascade boxes. Frame times on devices are not measured yet (no device; CI runs only offscreen correctness tests).

## GPU and streaming performance layer (SFPerf, added 2026-11-22)
New pure-Swift module `SFPerf` (Linux-testable) plus `SFRender/GPUTelemetry.swift`. Nothing here is measured on a device yet; it is the policy and accounting that the renderer hooks into.
- `MemoryBudget` / `MemoryLedger`: ceilings per platform (phone 1.5 GB, tablet 2.5 GB, Mac 4 GB, capped by a share of RAM), 400 MB OS headroom, caches halve on a memory warning and quarter when critical.
- `ASTCBlock`, `StreamingPlanner`, `ResidencyCache`, `LoadScheduler`: ASTC sizing (4x4 = 8 bpp, 6x6 = 3.56 bpp, 8x8 = 2 bpp), mip selection that fits a byte budget, LRU residency that never evicts this frame's tiles, and a priority load queue with an in-flight cap.
- `QualityGovernor` / `QualityLadder` / `QualityPlan`: the §11 ladder (resolution, density and distance, clouds, terrain SSE, shadows and ocean, frame cap) with ≥ 3 s hysteresis, slower recovery, thermal and Low Power floors, and `blended(to:t:)` so changes ramp.
- `FrameStats` / `RefreshPolicy`: p50, p99 and hitches per minute; 60/120/30 fps selection from display, platform, thermal state and Low Power Mode.
- `GPUTelemetry.attach` feeds command-buffer GPU time to the governor; `ASTCTextures` uploads pre-encoded ASTC tiles (encode offline with `astcenc`).

Hand-off for the renderer owner (WorldRenderer.swift and WorldShaders.swift are not touched here): wire `GPUTelemetry` into the frame commit and map `QualityPlan` onto `WorldRenderer.Settings`; merge passes where attachments allow (memoryless depth and MSAA on Apple GPUs); move per-cell draws to an indirect command buffer with GPU culling; and stage imagery through `ResidencyCache` with ASTC tiles.
