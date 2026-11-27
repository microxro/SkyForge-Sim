// SKYFORGE — Apache-2.0
// Particle-based hydraulic erosion on a square height window (row-major, index = y * width + x).
// Deterministic for a given RNG state. Particles stop at the sea and never leave the window.
import Foundation
import SFMath

enum HydraulicErosion {
    static let inertia = 0.05
    static let capacityFactor = 4.0
    static let minSlope = 0.01
    static let erodeRate = 0.3
    static let depositRate = 0.3
    static let evaporation = 0.01
    static let gravity = 4.0
    static let maxLifetime = 48
    static let brushRadius = 3

    struct Brush: Sendable {
        let dx: Int
        let dy: Int
        let weight: Double
    }

    /// Normalised radial brush, so one erosion event removes a fixed volume spread over the brush.
    static func makeBrush(radius: Int) -> [Brush] {
        var raw: [(Int, Int, Double)] = []
        var sum = 0.0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let d = (Double(dx * dx + dy * dy)).squareRoot()
                guard d <= Double(radius) else { continue }
                let w = 1 - d / Double(radius)
                raw.append((dx, dy, w))
                sum += w
            }
        }
        return raw.map { Brush(dx: $0.0, dy: $0.1, weight: $0.2 / sum) }
    }

    static func run(_ h: inout [Double], width w: Int, seaLevel: Double, particles: Int,
                    rng: inout Xoshiro256) {
        let brush = makeBrush(radius: brushRadius)
        let limit = Double(w - 2)
        for _ in 0..<particles {
            var px = 2 + rng.unit() * Double(w - 5)
            var py = 2 + rng.unit() * Double(w - 5)
            var dx = 0.0, dy = 0.0
            var speed = 1.0, water = 1.0, sediment = 0.0

            for _ in 0..<maxLifetime {
                let ix = Int(px), iy = Int(py)
                let fx = px - Double(ix), fy = py - Double(iy)
                let k = iy * w + ix
                let h00 = h[k], h10 = h[k + 1], h01 = h[k + w], h11 = h[k + w + 1]
                let height = h00 * (1 - fx) * (1 - fy) + h10 * fx * (1 - fy)
                    + h01 * (1 - fx) * fy + h11 * fx * fy
                if height < seaLevel { break }
                let gx = (h10 - h00) * (1 - fy) + (h11 - h01) * fy
                let gy = (h01 - h00) * (1 - fx) + (h11 - h10) * fx

                dx = dx * inertia - gx * (1 - inertia)
                dy = dy * inertia - gy * (1 - inertia)
                let len = (dx * dx + dy * dy).squareRoot()
                if len < 1e-9 { break }
                dx /= len
                dy /= len

                let nx = px + dx, ny = py + dy
                if nx < 1 || ny < 1 || nx > limit || ny > limit { break }
                let nix = Int(nx), niy = Int(ny)
                let nfx = nx - Double(nix), nfy = ny - Double(niy)
                let nk = niy * w + nix
                let newHeight = h[nk] * (1 - nfx) * (1 - nfy) + h[nk + 1] * nfx * (1 - nfy)
                    + h[nk + w] * (1 - nfx) * nfy + h[nk + w + 1] * nfx * nfy
                let dh = newHeight - height

                let capacity = max(-dh * speed * water * capacityFactor, minSlope)
                if sediment > capacity || dh > 0 {
                    // Deposit: fill a pit, or drop sediment when carrying more than the flow can hold.
                    let amount = dh > 0 ? min(dh, sediment) : (sediment - capacity) * depositRate
                    sediment -= amount
                    h[k] += amount * (1 - fx) * (1 - fy)
                    h[k + 1] += amount * fx * (1 - fy)
                    h[k + w] += amount * (1 - fx) * fy
                    h[k + w + 1] += amount * fx * fy
                } else {
                    // Erode: pick up material, spread over the brush and kept inside the window.
                    let amount = min((capacity - sediment) * erodeRate, -dh)
                    var removed = 0.0
                    for b in brush {
                        let bx = ix + b.dx, by = iy + b.dy
                        guard bx >= 0, by >= 0, bx < w, by < w else { continue }
                        let v = amount * b.weight
                        h[by * w + bx] -= v
                        removed += v
                    }
                    sediment += removed
                }

                speed = (max(0, speed * speed + dh * gravity)).squareRoot()
                water *= (1 - evaporation)
                px = nx
                py = ny
            }
        }
    }
}
