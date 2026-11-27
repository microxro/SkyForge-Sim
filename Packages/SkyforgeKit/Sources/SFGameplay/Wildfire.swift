// SKYFORGE — Apache-2.0
// A deterministic grass-fire model for the firefighting missions. The fire lives on a flat grid of cells
// (metres east and north of an origin). A cell that burns hot passes fire to its neighbours at a rate that rises
// downwind. A water drop cools the burning cells under it. There is no randomness, so the same ignition, wind,
// drops and time always give the same fire, which keeps missions replayable and tests exact.
// These are gameplay estimates for the scoring loop, not a fire-behaviour model.
import Foundation

public struct FireCell: Hashable, Sendable {
    public var i: Int
    public var j: Int
    public init(_ i: Int, _ j: Int) { self.i = i; self.j = j }
}

/// One drop from the aircraft: the water lands evenly on every cell whose centre is within `radius` of the point.
public struct WildfireDrop: Sendable, Equatable {
    public var east: Double
    public var north: Double
    public var radius: Double
    public var waterKg: Double
    public init(east: Double, north: Double, radius: Double, waterKg: Double) {
        self.east = east; self.north = north; self.radius = radius; self.waterKg = waterKg
    }
}

public struct DropOutcome: Sendable, Equatable {
    /// Cells under the drop, burning or not.
    public var cellsWetted: Int
    /// Burning cells under the drop.
    public var burningWetted: Int
    /// Water released by the drop (kg). It is all spent, even when it misses.
    public var waterUsedKg: Double

    /// Share of the drop that landed on burning cells (0...1).
    public var accuracy: Double {
        cellsWetted > 0 ? Double(burningWetted) / Double(cellsWetted) : 0
    }
}

public struct Wildfire: Sendable, Equatable {
    /// Side length of one grid cell (m).
    public static let cellSize = 50.0
    /// Hard cap on burning cells, so a runaway fire cannot grow without bound.
    public static let maxCells = 5_000
    /// Heat a cell must have to pass fire on to its neighbours.
    public static let spreadThreshold = 0.3
    /// Water (kg) that takes one full unit of heat out of one cell.
    public static let kgPerCellHeat = 800.0
    /// Base spread rate (neighbour-widths per second) with no wind.
    public static let baseSpreadRate = 0.02

    /// Wind carrying the fire, as the speed (m/s) it blows toward east and north.
    public var windEast: Double
    public var windNorth: Double

    /// Burning cells and their heat, 0...1. A cell is burning while it has heat above zero.
    public private(set) var heat: [FireCell: Double] = [:]
    /// Spread progress into unburnt neighbours. A neighbour ignites when its progress reaches 1.
    private var pressure: [FireCell: Double] = [:]
    /// Every cell that has ever burned. This is the burned area the career is scored on.
    public private(set) var everBurned: Int = 0
    public private(set) var elapsed: Double = 0

    public init(windEast: Double = 0, windNorth: Double = 0) {
        self.windEast = windEast.isFinite ? windEast : 0
        self.windNorth = windNorth.isFinite ? windNorth : 0
    }

    /// True once every cell is out.
    public var isOut: Bool { heat.isEmpty }
    /// Cells burning right now.
    public var burningCount: Int { heat.count }
    /// Area ever burned (hectares).
    public var burnedHectares: Double {
        Double(everBurned) * Self.cellSize * Self.cellSize / 10_000
    }

    static func cell(east: Double, north: Double) -> FireCell {
        FireCell(Int(floor(east / cellSize)), Int(floor(north / cellSize)))
    }

    /// Sets a fire burning on the cell at this point, at full heat.
    public mutating func ignite(east: Double, north: Double) {
        guard east.isFinite, north.isFinite else { return }
        igniteCell(Self.cell(east: east, north: north))
    }

    private mutating func igniteCell(_ c: FireCell) {
        guard heat[c] == nil, heat.count < Self.maxCells else { return }
        heat[c] = 1
        pressure[c] = nil
        everBurned += 1
    }

    /// Spread rate (1/s) from a burning cell toward a neighbour `(di, dj)` cells away.
    func spreadRate(di: Int, dj: Int) -> Double {
        let dist = sqrt(Double(di * di + dj * dj))
        let windSpeed = sqrt(windEast * windEast + windNorth * windNorth)
        var boost = 1.0
        if windSpeed > 0 {
            // Cosine of the angle between the spread direction and the wind.
            let cosine = (Double(di) * windEast + Double(dj) * windNorth) / (dist * windSpeed)
            // Wind helps up to about 10 m/s, and a headwind slows the fire to a fifth of its base rate.
            boost = 1 + 0.5 * cosine * min(windSpeed / 5, 2)
        }
        return Self.baseSpreadRate * max(0.2, boost) / dist
    }

    /// Advances the fire by `dt` seconds. Steps longer than 60 s are ignored, so a stalled frame cannot skip the fire.
    public mutating func step(dt: Double) {
        guard dt.isFinite, dt > 0, dt <= 60, !isOut else { return }
        elapsed += dt
        var spreading: [(FireCell, Double)] = []
        for (cell, h) in heat where h >= Self.spreadThreshold {
            spreading.append((cell, h))
        }
        // Sort so the result does not depend on dictionary order.
        spreading.sort { ($0.0.i, $0.0.j) < ($1.0.i, $1.0.j) }
        for (cell, h) in spreading {
            for di in -1...1 {
                for dj in -1...1 where !(di == 0 && dj == 0) {
                    let next = FireCell(cell.i + di, cell.j + dj)
                    guard heat[next] == nil else { continue }
                    pressure[next, default: 0] += spreadRate(di: di, dj: dj) * h * dt
                }
            }
        }
        for (c, p) in pressure.sorted(by: { ($0.key.i, $0.key.j) < ($1.key.i, $1.key.j) }) where p >= 1 {
            igniteCell(c)
        }
        pressure = pressure.filter { $0.value < 1 && heat[$0.key] == nil }
    }

    /// Releases one drop. Water is shared evenly across the cells under it. Burning cells lose heat, and a cell
    /// that reaches zero goes out.
    public mutating func drop(_ d: WildfireDrop) -> DropOutcome {
        guard d.east.isFinite, d.north.isFinite, d.radius.isFinite, d.waterKg.isFinite,
              d.radius > 0, d.radius <= 2_000, d.waterKg > 0 else {
            return DropOutcome(cellsWetted: 0, burningWetted: 0, waterUsedKg: 0)
        }
        let s = Self.cellSize
        let centre = Self.cell(east: d.east, north: d.north)
        let reach = Int(ceil(d.radius / s))
        var under: [FireCell] = []
        for di in -reach...reach {
            for dj in -reach...reach {
                let c = FireCell(centre.i + di, centre.j + dj)
                let cx = (Double(c.i) + 0.5) * s
                let cy = (Double(c.j) + 0.5) * s
                if hypot(cx - d.east, cy - d.north) <= d.radius { under.append(c) }
            }
        }
        let burning = under.filter { heat[$0] != nil }
        if !under.isEmpty {
            let perCell = d.waterKg / Double(under.count)
            for c in burning {
                let left = (heat[c] ?? 0) - perCell / Self.kgPerCellHeat
                if left > 0 { heat[c] = left } else { heat[c] = nil }
            }
        }
        return DropOutcome(cellsWetted: under.count, burningWetted: burning.count, waterUsedKg: d.waterKg)
    }
}
