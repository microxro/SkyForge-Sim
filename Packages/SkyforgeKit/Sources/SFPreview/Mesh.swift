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
    /// Optional per-vertex field weight (3 per triangle, 0…1): where `FieldPattern` parcels are drawn
    /// per pixel on terrain. Empty means no fields; once used it covers all triangles.
    public var vertexField: [Float] = []
    /// The parcel pattern `vertexField` refers to (set by SceneBuilder).
    public var fieldPattern: FieldPattern?
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
        if !vertexField.isEmpty { vertexField.append(0); vertexField.append(0); vertexField.append(0) }
    }

    /// Triangle with per-vertex colours (interpolated by both renderers).
    public mutating func add(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                             na: SIMD3<Float>, nb: SIMD3<Float>, nc: SIMD3<Float>,
                             ca: SIMD3<Float>, cb: SIMD3<Float>, cc: SIMD3<Float>, material m: Material,
                             fields: SIMD3<Float>? = nil) {
        if vertexAlbedo.isEmpty && !albedo.isEmpty { vertexAlbedo = albedo.flatMap { [$0, $0, $0] } }
        if let f = fields, f != .zero, vertexField.isEmpty { vertexField = [Float](repeating: 0, count: 3 * material.count) }
        if !vertexField.isEmpty { let f = fields ?? .zero; vertexField.append(f.x); vertexField.append(f.y); vertexField.append(f.z) }
        positions.append(local(a)); positions.append(local(b)); positions.append(local(c))
        normals.append(na); normals.append(nb); normals.append(nc)
        albedo.append((ca + cb + cc) / 3); material.append(m)
        vertexAlbedo.append(ca); vertexAlbedo.append(cb); vertexAlbedo.append(cc)
    }

    /// Albedo of vertex `k` (0…2) of triangle `t`.
    @inline(__always) public func colour(_ t: Int, _ k: Int) -> SIMD3<Float> {
        vertexAlbedo.isEmpty ? albedo[t] : vertexAlbedo[3 * t + k]
    }

    /// Field weight of vertex `k` of triangle `t` (0 when the soup has no fields).
    @inline(__always) public func field(_ t: Int, _ k: Int) -> Float {
        vertexField.isEmpty ? 0 : vertexField[3 * t + k]
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

extension TriangleSoup {
    /// Replaces normals of triangles `range` with crease-aware smooth normals: each vertex averages the
    /// face normals of triangles sharing its position whose normals are within `creaseDegrees`
    /// (art review: faceted, flat-normal aircraft).
    public mutating func smoothNormals(triangles range: Range<Int>, creaseDegrees: Float = 50) {
        let creaseCos = cos(creaseDegrees * .pi / 180)
        func dotf(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
        func lenf(_ a: SIMD3<Float>) -> Float { dotf(a, a).squareRoot() }
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3(Int32((p.x * 1000).rounded()), Int32((p.y * 1000).rounded()), Int32((p.z * 1000).rounded())) }
        var face = [SIMD3<Float>](repeating: .zero, count: range.count)
        var incident: [SIMD3<Int32>: [Int]] = [:]
        for (i, t) in range.enumerated() {
            let a = positions[3 * t], b = positions[3 * t + 1], c = positions[3 * t + 2]
            let e1 = b - a, e2 = c - a
            let n = SIMD3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x)
            let l = lenf(n)
            face[i] = l > 0 ? n / l : SIMD3(0, 0, 1)
            for k in 0..<3 { incident[key(positions[3 * t + k]), default: []].append(i) }
        }
        for (i, t) in range.enumerated() {
            for k in 0..<3 {
                var sum = SIMD3<Float>.zero
                for j in incident[key(positions[3 * t + k])] ?? [] where dotf(face[j], face[i]) >= creaseCos { sum += face[j] }
                let l = lenf(sum)
                normals[3 * t + k] = l > 0 ? sum / l : face[i]
            }
        }
    }
}
