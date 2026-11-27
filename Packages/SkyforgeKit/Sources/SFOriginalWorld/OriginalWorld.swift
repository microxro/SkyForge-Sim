// SKYFORGE — Apache-2.0
// SFOriginalWorld: procedural terrain for SkyForge's original open world (an alternative to Earth).
// Pure Swift and deterministic: every chunk is a function of (seed, chunk coordinates) only.
// Chunks carry a halo so that erosion and hydrology see their neighbours. See docs/WORLD_TERRAIN.md.
import Foundation
import SFMath

public enum OriginalWorldInfo {
    /// Bumped whenever generated output changes; part of every chunk cache key.
    public static let terrainVersion = 1
}

public struct OriginalWorldSpec: Sendable, Equatable {
    public let seed: UInt64
    /// Chunk edge length in metres.
    public let chunkSize: Double
    /// Height samples per chunk side, both edges included. Spacing = chunkSize / (cellsPerSide - 1).
    public let cellsPerSide: Int
    /// Extra samples on every side, used only as erosion and hydrology context.
    public let haloCells: Int
    /// Hydraulic erosion particles per chunk window (strength and cost).
    public let erosionParticles: Int
    /// Drainage cells needed before a channel counts as a river.
    public let riverThreshold: Int
    public let seaLevel: Double

    public init(seed: UInt64, chunkSize: Double = 1_024, cellsPerSide: Int = 65, haloCells: Int = 16,
                erosionParticles: Int = 30_000, riverThreshold: Int = 260, seaLevel: Double = 0) {
        precondition(cellsPerSide >= 9 && haloCells >= 4, "chunk too small for erosion context")
        self.seed = seed
        self.chunkSize = chunkSize
        self.cellsPerSide = cellsPerSide
        self.haloCells = haloCells
        self.erosionParticles = erosionParticles
        self.riverThreshold = riverThreshold
        self.seaLevel = seaLevel
    }

    public var spacing: Double { chunkSize / Double(cellsPerSide - 1) }
}

/// One generated chunk: interior samples only (the halo is cropped away).
public struct OriginalTerrainChunk: Sendable {
    public let cx: Int
    public let cy: Int
    /// World-metre position of sample (0, 0).
    public let originX: Double
    public let originY: Double
    public let cellsPerSide: Int
    public let spacing: Double
    /// Row-major, index = j * cellsPerSide + i. i grows east, j grows north. Metres above sea level.
    public let heights: [Float]
    public let biomes: [OriginalBiome]
    public let water: [WaterKind]
    /// Hash of every output value; equal hashes mean identical chunks.
    public let contentHash: UInt64

    public func height(_ i: Int, _ j: Int) -> Float { heights[j * cellsPerSide + i] }

    /// Heights sampled every `step` cells, for an LOD level. `step` must divide `cellsPerSide - 1`.
    public func decimated(step: Int) -> [Float] {
        precondition(step > 0 && (cellsPerSide - 1) % step == 0, "step must divide the chunk")
        let m = (cellsPerSide - 1) / step + 1
        var out = [Float]()
        out.reserveCapacity(m * m)
        for jj in 0..<m {
            for ii in 0..<m {
                out.append(heights[(jj * step) * cellsPerSide + ii * step])
            }
        }
        return out
    }
}

/// Generates chunks of the original world. Stateless apart from the spec, so it is safe to share.
public struct OriginalWorldGenerator: Sendable {
    public let spec: OriginalWorldSpec
    let field: BaseField

    public init(spec: OriginalWorldSpec) {
        self.spec = spec
        field = BaseField(seed: spec.seed)
    }

    /// Base elevation (metres) at a world position, before erosion. Pure and seam-free.
    public func baseHeight(x: Double, y: Double) -> Double { field.height(x, y) }

    public func chunk(cx: Int, cy: Int) -> OriginalTerrainChunk {
        let n = spec.cellsPerSide, halo = spec.haloCells
        let w = n + 2 * halo
        let sp = spec.spacing
        let originX = Double(cx) * spec.chunkSize
        let originY = Double(cy) * spec.chunkSize
        let windowX = originX - Double(halo) * sp
        let windowY = originY - Double(halo) * sp

        var grid = [Double](repeating: 0, count: w * w)
        for j in 0..<w {
            for i in 0..<w {
                grid[j * w + i] = field.height(windowX + Double(i) * sp, windowY + Double(j) * sp)
            }
        }

        var rng = Xoshiro256(seed: Hash.combine(spec.seed, UInt64(bitPattern: Int64(cx)),
                                                UInt64(bitPattern: Int64(cy)), 0xE205))
        HydraulicErosion.run(&grid, width: w, seaLevel: spec.seaLevel,
                             particles: spec.erosionParticles, rng: &rng)
        let hydro = Hydrology.analyse(grid, width: w, seaLevel: spec.seaLevel,
                                      riverThreshold: spec.riverThreshold)

        var heights = [Float](), biomes = [OriginalBiome](), water = [WaterKind]()
        heights.reserveCapacity(n * n); biomes.reserveCapacity(n * n); water.reserveCapacity(n * n)
        for j in 0..<n {
            for i in 0..<n {
                let gi = (j + halo) * w + (i + halo)
                let h = grid[gi]
                let x = windowX + Double(i + halo) * sp
                let y = windowY + Double(j + halo) * sp
                let slope = Self.slope(grid, w: w, gi: gi, spacing: sp)
                let acc = hydro.accumulation[gi]
                let wet = min(1, log2(Double(acc) + 1) / 7)
                let moisture = clamp(0.5 + 0.3 * field.moistureNoise(x, y) + 0.25 * wet, 0, 1)
                let temperature = 14 + 7 * field.climateNoise(x, y) - 0.0065 * h
                let kind = hydro.water[gi]
                heights.append(Float(h))
                water.append(kind)
                biomes.append(OriginalBiomeRules.classify(height: h, slope: slope, moisture: moisture,
                                                          temperatureC: temperature, water: kind,
                                                          seaLevel: spec.seaLevel))
            }
        }

        var hash: UInt64 = 0x5F0F_2026
        for v in heights { hash = Hash.mix(hash ^ UInt64(v.bitPattern)) }
        for b in biomes { hash = Hash.mix(hash ^ UInt64(b.rawValue)) }
        for k in water { hash = Hash.mix(hash ^ UInt64(k.rawValue) ^ 0x100) }

        return OriginalTerrainChunk(cx: cx, cy: cy, originX: originX, originY: originY,
                                    cellsPerSide: n, spacing: sp, heights: heights,
                                    biomes: biomes, water: water, contentHash: hash)
    }

    /// Slope as rise over run from central differences on the window grid.
    static func slope(_ g: [Double], w: Int, gi: Int, spacing: Double) -> Double {
        let gx = (g[gi + 1] - g[gi - 1]) / (2 * spacing)
        let gy = (g[gi + w] - g[gi - w]) / (2 * spacing)
        return (gx * gx + gy * gy).squareRoot()
    }
}
