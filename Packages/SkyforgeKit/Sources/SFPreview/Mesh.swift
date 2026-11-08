// SKYFORGE — Apache-2.0
// Triangle soup used by the CPU preview renderer. Positions are camera-relative Float (floating origin).
import Foundation
import SFMath
import SFWorldGen

public enum Material: UInt8, Sendable {
    case opaque = 0, water = 1, foliage = 2, road = 3, emissive = 4, glass = 5, paint = 6, terrain = 7
}

public struct TriangleSoup: Sendable {
    public var positions: [SIMD3<Float>] = []   // 3 per triangle
    public var normals: [SIMD3<Float>] = []     // 3 per triangle
    public var albedo: [SIMD3<Float>] = []      // 1 per triangle
    public var material: [Material] = []        // 1 per triangle
    /// Optional per-vertex albedo (3 per triangle) for smooth colour transitions; empty when every
    /// triangle is flat-coloured. Once used it covers all triangles (flat ones repeat `albedo`).
    public var vertexAlbedo: [SIMD3<Float>] = []
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
        if !vertexAlbedo.isEmpty { vertexAlbedo.append(colour); vertexAlbedo.append(colour); vertexAlbedo.append(colour) }
    }

    /// Triangle with per-vertex colours (interpolated by both renderers).
    public mutating func add(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                             na: SIMD3<Float>, nb: SIMD3<Float>, nc: SIMD3<Float>,
                             ca: SIMD3<Float>, cb: SIMD3<Float>, cc: SIMD3<Float>, material m: Material) {
        if vertexAlbedo.isEmpty && !albedo.isEmpty { vertexAlbedo = albedo.flatMap { [$0, $0, $0] } }
        positions.append(local(a)); positions.append(local(b)); positions.append(local(c))
        normals.append(na); normals.append(nb); normals.append(nc)
        albedo.append((ca + cb + cc) / 3); material.append(m)
        vertexAlbedo.append(ca); vertexAlbedo.append(cb); vertexAlbedo.append(cc)
    }

    /// Albedo of vertex `k` (0…2) of triangle `t`.
    @inline(__always) public func colour(_ t: Int, _ k: Int) -> SIMD3<Float> {
        vertexAlbedo.isEmpty ? albedo[t] : vertexAlbedo[3 * t + k]
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
