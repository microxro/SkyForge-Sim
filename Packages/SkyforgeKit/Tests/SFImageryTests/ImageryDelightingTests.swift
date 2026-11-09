// SKYFORGE — Apache-2.0
import Testing
@testable import SFImagery

@Suite struct ImageryDelightingTests {
    /// 256 px over 256 m (1 m/px), centred at the origin; pixel (i, j) is at x = i − 127.5, y = 127.5 − j.
    static func mosaic(_ f: (Int, Int) -> SIMD3<UInt8>) -> ImageryMosaic {
        let n = 256
        var rgb = [UInt8](repeating: 0, count: n * n * 3)
        for j in 0..<n { for i in 0..<n { let c = f(i, j); rgb[3 * (j * n + i)] = c.x; rgb[3 * (j * n + i) + 1] = c.y; rgb[3 * (j * n + i) + 2] = c.z } }
        return ImageryMosaic(centre: .zero, halfExtent: 128, size: n, rgb: rgb, coverage: [UInt8](repeating: 255, count: n * n), zoom: 18)
    }
    static let ground = SIMD3<UInt8>(170, 160, 130)
    static func px(_ m: ImageryMosaic, _ i: Int, _ j: Int) -> SIMD3<Int> {
        let p = 3 * (j * m.size + i)
        return SIMD3(Int(m.rgb[p]), Int(m.rgb[p + 1]), Int(m.rgb[p + 2]))
    }
    static func pos(_ i: Int, _ j: Int) -> SIMD2<Double> { SIMD2(Double(i) - 127.5, 127.5 - Double(j)) }

    /// A photo tree (green blob) and its shadow under a placed 3D tree are filled with the lit ground; the
    /// same blob and shadow where no 3D tree stands, and the lit ground itself, are untouched.
    @Test func photoTreeAndShadowUnderA3DTreeAreFilled() {
        func blob(_ i: Int, _ j: Int, _ ci: Int, _ cj: Int) -> SIMD3<UInt8>? {
            let d2 = (i - ci) * (i - ci) + (j - cj) * (j - cj)
            if d2 <= 16 { return SIMD3(40, 70, 35) }                                  // crown, 4 m radius
            if (i - ci - 5) * (i - ci - 5) + (j - cj - 2) * (j - cj - 2) <= 9 { return SIMD3(45, 45, 55) }   // its shadow
            return nil
        }
        let m0 = Self.mosaic { i, j in blob(i, j, 64, 64) ?? blob(i, j, 192, 192) ?? Self.ground }
        var m = m0
        let changed = ImageryDelighting.removePhotoTrees(&m, crowns: [ImageryDelighting.Crown(centre: Self.pos(64, 64), radius: 9)])
        #expect(changed > 50, "changed \(changed)")
        let g = SIMD3(Int(Self.ground.x), Int(Self.ground.y), Int(Self.ground.z))
        for (i, j) in [(64, 64), (66, 63), (69, 66)] {          // crown centre, crown, shadow
            let d = Self.px(m, i, j) &- g
            #expect(abs(d.x) + abs(d.y) + abs(d.z) < 24, "(\(i),\(j)) = \(Self.px(m, i, j))")
        }
        #expect(Self.px(m, 192, 192) == Self.px(m0, 192, 192), "photo tree without a 3D tree kept")
        #expect(Self.px(m, 197, 194) == Self.px(m0, 197, 194), "its shadow kept")
        #expect(Self.px(m, 100, 30) == g, "lit ground unchanged")
    }

    /// Water inside a tree disc is never filled.
    @Test func waterIsKept() {
        let m0 = Self.mosaic { i, j in i < 128 ? SIMD3(30, 45, 60) : Self.ground }
        var m = m0
        ImageryDelighting.removePhotoTrees(&m, crowns: [ImageryDelighting.Crown(centre: Self.pos(128, 128), radius: 12)]) { x, _ in x < 0 ? 1 : 0 }
        #expect(Self.px(m, 122, 128) == Self.px(m0, 122, 128))
    }

    /// Closed canopy (nothing lit within ~25 m) is left as photographed, never filled with an invented colour.
    @Test func closedForestIsLeftAlone() {
        let m0 = Self.mosaic { i, j in (i + j) % 7 == 0 ? SIMD3(25, 50, 30) : SIMD3(40, 75, 38) }
        var m = m0
        var crowns: [ImageryDelighting.Crown] = []
        for j in stride(from: 8, to: 256, by: 8) { for i in stride(from: 8, to: 256, by: 8) { crowns.append(.init(centre: Self.pos(i, j), radius: 7)) } }
        ImageryDelighting.removePhotoTrees(&m, crowns: crowns)
        #expect(Self.px(m, 128, 128) == Self.px(m0, 128, 128))
    }

    /// Push-pull on its own: a hole takes the colours around it, and known pixels are exact.
    @Test func inpaintFillsHolesFromNeighbours() {
        let w = 32, h = 20
        var rgb = [UInt8](repeating: 0, count: w * h * 3), mask = [Float](repeating: 0, count: w * h)
        for j in 0..<h { for i in 0..<w {
            let p = j * w + i
            rgb[3 * p] = i < 16 ? 200 : 100; rgb[3 * p + 1] = 50; rgb[3 * p + 2] = 50
            if abs(i - 8) < 3 && abs(j - 10) < 3 { mask[p] = 1; rgb[3 * p] = 0; rgb[3 * p + 1] = 0; rgb[3 * p + 2] = 0 }
        } }
        ImageryDelighting.inpaint(rgb: &rgb, width: w, height: h, mask: mask)
        let c = 3 * (10 * w + 8)
        #expect(abs(Int(rgb[c]) - 200) < 20 && abs(Int(rgb[c + 1]) - 50) < 8, "\(rgb[c...c + 2])")
        #expect(rgb[3 * (2 * w + 25)] == 100, "known pixel unchanged")
    }
}
