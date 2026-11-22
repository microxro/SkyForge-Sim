// SKYFORGE — Apache-2.0
// Pure Swift (Linux-testable). ASTC sizing, LRU residency and a prioritised async-load queue.
import Foundation

/// ASTC LDR block footprints. Every block is 16 bytes, so bits per pixel = 128 / (w × h).
public enum ASTCBlock: String, Sendable, CaseIterable {
    case b4x4, b5x5, b6x6, b8x8

    public var footprint: (w: Int, h: Int) {
        switch self {
        case .b4x4: (4, 4)
        case .b5x5: (5, 5)
        case .b6x6: (6, 6)
        case .b8x8: (8, 8)
        }
    }
    public var bitsPerPixel: Double { 128.0 / Double(footprint.w * footprint.h) }

    /// Largest texture edge accepted. Dimensions come from tile headers, so they are clamped before any
    /// multiplication (16384² at 4×4 is 256 MiB, far from overflowing Int).
    public static let maxDimension = 16_384
    static func clampDim(_ v: Int) -> Int { min(maxDimension, max(1, v)) }

    public func byteSize(width: Int, height: Int) -> Int {
        let f = footprint
        let bw = (Self.clampDim(width) + f.w - 1) / f.w
        let bh = (Self.clampDim(height) + f.h - 1) / f.h
        return bw * bh * 16
    }

    /// Row stride for `MTLTexture.replace(region:mipmapLevel:withBytes:bytesPerRow:)`.
    public func bytesPerRow(width: Int) -> Int { ((Self.clampDim(width) + footprint.w - 1) / footprint.w) * 16 }

    /// Number of mips in a full chain for these dimensions.
    public static func mipCount(width: Int, height: Int) -> Int {
        var m = max(clampDim(width), clampDim(height)), n = 1
        while m > 1 { m /= 2; n += 1 }
        return n
    }

    /// Total bytes for mips `firstMip...` of a full chain (mip 0 is `width × height`).
    public func chainByteSize(width: Int, height: Int, firstMip: Int = 0) -> Int {
        var w = Self.clampDim(width), h = Self.clampDim(height), total = 0, level = 0
        while true {
            if level >= firstMip { total += byteSize(width: w, height: h) }
            if w == 1 && h == 1 { break }
            w = max(1, w / 2); h = max(1, h / 2); level += 1
        }
        return total
    }
}

public struct StreamedTile: Sendable, Equatable {
    public let id: UInt64
    public let width: Int, height: Int
    public let block: ASTCBlock
    /// Estimated on-screen size in pixels (larger = more important).
    public let screenPixels: Double
    public init(id: UInt64, width: Int, height: Int, block: ASTCBlock, screenPixels: Double) {
        self.id = id; self.width = width; self.height = height; self.block = block; self.screenPixels = screenPixels
    }
}

public enum StreamingPlanner {
    /// First mip each tile should keep resident. Starts from the mip whose texel density matches the
    /// screen footprint, then drops the least valuable tile's top mip until the total fits `budget`.
    /// Tiles never go below a 1×1 mip, so the result may exceed an unreachably small budget.
    public static func firstMips(_ input: [StreamedTile], budget: Int) -> [UInt64: Int] {
        // Duplicate ids would share one entry in `first`, so only the first occurrence counts.
        var seen = Set<UInt64>()
        let tiles = input.filter { seen.insert($0.id).inserted }
        var first: [UInt64: Int] = [:]
        func pixels(_ t: StreamedTile) -> Double { t.screenPixels.isFinite ? max(1, t.screenPixels) : 1 }
        for t in tiles {
            let ratio = Double(ASTCBlock.clampDim(max(t.width, t.height))) / pixels(t)
            first[t.id] = ratio <= 1 ? 0 : Int(log2(ratio).rounded(.down))
        }
        func bytes(_ t: StreamedTile) -> Int {
            t.block.chainByteSize(width: t.width, height: t.height, firstMip: first[t.id] ?? 0)
        }
        func maxMip(_ t: StreamedTile) -> Int { ASTCBlock.mipCount(width: t.width, height: t.height) - 1 }
        for t in tiles { first[t.id] = min(first[t.id] ?? 0, maxMip(t)) }
        var total = tiles.reduce(0) { $0 + bytes($1) }
        // Cheapest visual loss first: smallest on-screen tiles drop a mip before large ones.
        let order = tiles.sorted { pixels($0) < pixels($1) }
        while total > budget {
            var progressed = false
            for t in order where total > budget {
                let cur = first[t.id] ?? 0
                guard cur < maxMip(t) else { continue }
                let before = bytes(t)
                first[t.id] = cur + 1
                total -= before - bytes(t)
                progressed = true
            }
            if !progressed { break }
        }
        return first
    }
}

/// LRU residency set with a byte budget. Entries touched this frame are never evicted.
public struct ResidencyCache: Sendable {
    private struct Entry { var bytes: Int; var lastUsed: UInt64 }
    private var entries: [UInt64: Entry] = [:]
    public private(set) var resident = 0
    public private(set) var budget: Int
    private var tick: UInt64 = 0
    private var pinnedTick: UInt64 = 0

    public init(budget: Int) { self.budget = max(0, budget) }

    public var count: Int { entries.count }
    public func contains(_ id: UInt64) -> Bool { entries[id] != nil }

    /// Start a frame; anything `touch`ed or `insert`ed afterwards is protected from eviction.
    public mutating func beginFrame() { tick += 1; pinnedTick = tick }

    public mutating func touch(_ id: UInt64) {
        entries[id]?.lastUsed = tick
    }

    /// Adds (or resizes) an entry and evicts least-recently-used ones to fit. Returns evicted ids so the
    /// owner can release GPU textures; protected entries stay even if that leaves the cache over budget.
    @discardableResult
    public mutating func insert(_ id: UInt64, bytes: Int) -> [UInt64] {
        if let old = entries[id] { resident -= old.bytes }
        entries[id] = Entry(bytes: max(0, bytes), lastUsed: tick)
        resident += max(0, bytes)
        return evict()
    }

    @discardableResult
    public mutating func remove(_ id: UInt64) -> Bool {
        guard let e = entries.removeValue(forKey: id) else { return false }
        resident -= e.bytes
        return true
    }

    /// Applies a new budget (memory warning, thermal step) and returns the evicted ids.
    @discardableResult
    public mutating func setBudget(_ newBudget: Int) -> [UInt64] {
        budget = max(0, newBudget)
        // A budget cut is a memory warning: protection of this frame's entries is lifted so the cut always
        // lands (the owner re-requests what it still needs next frame).
        return evict(includingPinned: true)
    }

    private mutating func evict(includingPinned: Bool = false) -> [UInt64] {
        guard resident > budget else { return [] }
        let victims = entries.filter { includingPinned || $0.value.lastUsed < pinnedTick || pinnedTick == 0 }
            .sorted { ($0.value.lastUsed, $0.key) < ($1.value.lastUsed, $1.key) }
        var out: [UInt64] = []
        for (id, e) in victims where resident > budget {
            entries[id] = nil
            resident -= e.bytes
            out.append(id)
        }
        return out
    }
}

/// Async load queue: highest priority first, a cap on concurrent loads so I/O and decode never starve
/// the render thread, stale requests (no longer wanted) dropped before they start.
public struct LoadScheduler: Sendable {
    public struct Request: Sendable, Equatable {
        public let id: UInt64
        public var priority: Double
        public init(id: UInt64, priority: Double) { self.id = id; self.priority = priority }
    }
    public let maxInFlight: Int
    private var queued: [UInt64: Double] = [:]
    public private(set) var inFlight: Set<UInt64> = []

    public init(maxInFlight: Int) { self.maxInFlight = max(1, maxInFlight) }

    public var pending: Int { queued.count }

    /// Replaces the wanted set: unseen ids are queued, reprioritised ones updated, dropped ones forgotten.
    /// Ids already loading finish regardless.
    public mutating func want(_ requests: [Request], resident: Set<UInt64> = []) {
        var next: [UInt64: Double] = [:]
        for r in requests where !inFlight.contains(r.id) && !resident.contains(r.id) {
            // NaN sorts inconsistently; treat it as the lowest priority.
            next[r.id] = r.priority.isNaN ? -Double.greatestFiniteMagnitude : r.priority
        }
        queued = next
    }

    /// Ids to start now, best first, up to the free in-flight slots.
    public mutating func next() -> [UInt64] {
        let slots = maxInFlight - inFlight.count
        guard slots > 0 else { return [] }
        let picks = queued.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(slots).map(\.key)
        for id in picks { queued[id] = nil; inFlight.insert(id) }
        return picks
    }

    public mutating func finished(_ id: UInt64) { inFlight.remove(id) }
}
