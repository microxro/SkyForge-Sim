// SKYFORGE — Apache-2.0
// Hydrology on a height window: depression filling (lakes), D8 flow routing, flow accumulation,
// and river and lake masks. Priority-flood fill after Barnes et al. (2014), simplified.
import Foundation

public enum WaterKind: UInt8, Sendable, CaseIterable {
    case none, sea, lake, river
}

struct HydroResult: Sendable {
    /// Height after depression filling (lake surfaces sit at these heights).
    let filled: [Double]
    /// Index of the lowest neighbour a cell drains into; -1 for window edges.
    let receiver: [Int]
    /// Number of window cells draining through each cell, including itself.
    let accumulation: [Int]
    let water: [WaterKind]
}

enum Hydrology {
    /// Epsilon that keeps filled surfaces sloping towards their outlet, so routing never stalls.
    static let epsilon = 1e-4
    /// Neighbour offsets, as flat x and y pairs.
    static let dxs = [-1, 0, 1, -1, 1, -1, 0, 1]
    static let dys = [-1, -1, -1, 0, 0, 1, 1, 1]

    static func analyse(_ h: [Double], width w: Int, seaLevel: Double, riverThreshold: Int) -> HydroResult {
        let count = w * w
        let filled = fill(h, width: w)

        var receiver = [Int](repeating: -1, count: count)
        for j in 1..<(w - 1) {
            for i in 1..<(w - 1) {
                let k = j * w + i
                var best = k
                var bestHeight = filled[k]
                for d in 0..<8 {
                    let n = (j + dys[d]) * w + (i + dxs[d])
                    if filled[n] < bestHeight {
                        bestHeight = filled[n]
                        best = n
                    }
                }
                receiver[k] = best == k ? -1 : best
            }
        }

        // Highest cells first, so every upstream contribution is added before a cell passes its total on.
        let order = (0..<count).sorted { filled[$0] > filled[$1] }
        var accumulation = [Int](repeating: 1, count: count)
        for k in order {
            let r = receiver[k]
            if r >= 0 { accumulation[r] += accumulation[k] }
        }

        var water = [WaterKind](repeating: .none, count: count)
        for k in 0..<count {
            if h[k] < seaLevel {
                water[k] = .sea
            } else if filled[k] - h[k] > 0.05 {
                water[k] = .lake
            } else if accumulation[k] >= riverThreshold {
                water[k] = .river
            }
        }
        return HydroResult(filled: filled, receiver: receiver, accumulation: accumulation, water: water)
    }

    /// Priority-flood: raises pits to their spill height so every interior cell can drain outward.
    static func fill(_ h: [Double], width w: Int) -> [Double] {
        var filled = h
        var closed = [Bool](repeating: false, count: w * w)
        var heap = MinHeap()
        for j in 0..<w {
            for i in 0..<w where i == 0 || j == 0 || i == w - 1 || j == w - 1 {
                let k = j * w + i
                closed[k] = true
                heap.push(key: h[k], value: k)
            }
        }
        while let top = heap.pop() {
            let c = top.value
            let ci = c % w, cj = c / w
            for d in 0..<8 {
                let ni = ci + dxs[d], nj = cj + dys[d]
                guard ni >= 0, nj >= 0, ni < w, nj < w else { continue }
                let n = nj * w + ni
                if closed[n] { continue }
                closed[n] = true
                filled[n] = max(h[n], filled[c] + epsilon)
                heap.push(key: filled[n], value: n)
            }
        }
        return filled
    }
}

/// Binary min-heap keyed by Double, used by the priority-flood fill.
struct MinHeap {
    struct Entry {
        let key: Double
        let value: Int
    }

    private var items: [Entry] = []

    mutating func push(key: Double, value: Int) {
        items.append(Entry(key: key, value: value))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].key <= items[i].key { break }
            items.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> Entry? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].key < items[m].key { m = l }
                if r < items.count && items[r].key < items[m].key { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
