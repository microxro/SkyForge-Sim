// SKYFORGE — Apache-2.0
// Triangle soup used by the CPU preview renderer. Positions are camera-relative Float (floating origin).
import Foundation
import SFMath
import SFWorldGen

public enum Material: UInt8, Sendable {
    case opaque = 0, water = 1, foliage = 2, road = 3, emissive = 4, glass = 5, paint = 6
}

public struct TriangleSoup: Sendable {
    public var positions: [SIMD3<Float>] = []   // 3 per triangle
    public var normals: [SIMD3<Float>] = []     // 3 per triangle
    public var albedo: [SIMD3<Float>] = []      // 1 per triangle
    public var material: [Material] = []        // 1 per triangle
    public let origin: SIMD3<Double>

    public init(origin: SIMD3<Double>) { self.origin = origin }

    public var triangleCount: Int { material.count }

    @inline(__always) func local(_ p: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(Float(p.x - origin.x), Float(p.y - origin.y), Float(p.z - origin.z))
    }

    public mutating func add(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                             na: SIMD3<Float>, nb: SIMD3<Float>, nc: SIMD3<Float>,
                             colour: SIMD3<Float>, material m: Material) {
        positions.append(local(a)); positions.append(local(b)); positions.append(local(c))
        normals.append(na); normals.append(nb); normals.append(nc)
        albedo.append(colour); material.append(m)
    }

    /// Flat-shaded triangle (normal from winding, counter-clockwise seen from outside).
    public mutating func addFlat(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, colour: SIMD3<Float>, material m: Material = .opaque) {
        let n = normalize(cross(b - a, c - a))
        let nf = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        add(a, b, c, na: nf, nb: nf, nc: nf, colour: colour, material: m)
    }

    public mutating func addQuad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, colour: SIMD3<Float>, material m: Material = .opaque) {
        addFlat(a, b, c, colour: colour, material: m)
        addFlat(a, c, d, colour: colour, material: m)
    }
}
