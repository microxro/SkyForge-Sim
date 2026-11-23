// SKYFORGE — Apache-2.0
// Streams Terrarium tiles: memory cache -> content-addressed disk cache -> network (<= 8 concurrent),
// falling back to the bundled global baseline when offline so flight never waits on the network.
import Foundation
import SFMath
import SFContent

public actor TerrainStreamer {
    public enum Source: String, Sendable { case memory, disk, network, baseline }

    let transport: any HTTPTransport
    let cache: KeyedCache?
    let baseline: GlobalDEM?
    var memory: [TileCoord: HeightGrid] = [:]
    var memoryOrder: [TileCoord] = []
    let memoryLimit: Int
    var inFlight = 0
    /// Callers waiting for a network slot. A released slot is handed straight to the next waiter.
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    public let maxConcurrent = 8
    public private(set) var networkRequests = 0

    public init(transport: any HTTPTransport, cache: KeyedCache?, baseline: GlobalDEM?, memoryLimit: Int = 256) {
        self.transport = transport; self.cache = cache; self.baseline = baseline; self.memoryLimit = memoryLimit
    }

    /// Returns the height grid for a tile and where it came from.
    public func tile(_ t: TileCoord) async -> (HeightGrid, Source) {
        if let g = memory[t] { return (g, .memory) }
        let key = Terrarium.url(for: t)
        if let cache, let data = await cache.get(key), let g = await decodeTerrariumOffActor(data) {
            remember(t, g)
            return (g, .disk)
        }
        await acquireSlot()
        defer { releaseSlot() }
        networkRequests += 1
        if let url = URL(string: key), let data = try? await transport.get(url), let g = await decodeTerrariumOffActor(data) {
            if let cache { try? await cache.put(key, data) }
            remember(t, g)
            return (g, .network)
        }
        return (baselineGrid(t), .baseline)
    }

    /// Suspends (no spinning) until one of the `maxConcurrent` network slots is free.
    private func acquireSlot() async {
        if inFlight < maxConcurrent {
            inFlight += 1
        } else {
            await withCheckedContinuation { slotWaiters.append($0) }   // the releasing caller transfers its slot
        }
    }

    private func releaseSlot() {
        if !slotWaiters.isEmpty {
            slotWaiters.removeFirst().resume()
        } else {
            inFlight -= 1
        }
    }

    func remember(_ t: TileCoord, _ g: HeightGrid) {
        memory[t] = g
        memoryOrder.append(t)
        if memoryOrder.count > memoryLimit { memory[memoryOrder.removeFirst()] = nil }
    }

    /// 64x64 grid resampled from the bundled baseline (or sea level if none).
    func baselineGrid(_ t: TileCoord) -> HeightGrid {
        let n = 64
        var s = [Float](repeating: 0, count: n * n)
        if let baseline {
            for j in 0..<n {
                for i in 0..<n {
                    let c = t.coordinate(u: (Double(i) + 0.5) / Double(n), v: (Double(j) + 0.5) / Double(n))
                    s[j * n + i] = Float(baseline.elevation(latitude: c.latitude, longitude: c.longitude))
                }
            }
        }
        return HeightGrid(width: n, height: n, samples: s)
    }
}

/// PNG inflate is CPU-heavy. Run it on the global executor so the streamer actor keeps serving other requests.
func decodeTerrariumOffActor(_ data: Data) async -> HeightGrid? {
    await Task.detached(priority: .utility) { try? Terrarium.decode(png: [UInt8](data)) }.value
}
