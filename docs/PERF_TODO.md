# Performance work needing a Mac / device (C11, C12)

No Swift toolchain was available when these changes were made, so nothing here was compiled or run.

## Verify on a Mac
- `swift test --filter SFTerrainCoreTests` (PNG unfilter, Terrarium decode, CDLOD selection must be unchanged).
- Terrarium output must be bit-identical to before (Float math is exact for 24 bits).

## Profile on device (Instruments)
- Metal System Trace on iPhone and iPad: frame time, draw calls, GPU overdraw at KMRY, KASE and KBFI.
- Allocations: confirm no per-frame heap growth in the render loop and the terrain stream.
- Time Profiler: `Inflate.codes` and `Huffman.decode` (bit-by-bit decode; a 9-bit lookup table is the next win).
- Metal GPU capture: terrain chunk count after CDLOD selection, and shadow cascade cost.

## Owned by the airport-frames thread (not touched here)
- WorldRenderer.swift and WorldShaders.swift: per-frame buffer allocation audit, draw call merging.
