// SKYFORGE — Apache-2.0
// CPU rasterizer for DrawList: non-zero scanline fill with 4 sub-rows per pixel and exact
// horizontal coverage, clip stack of rects/circles, straight-alpha "over" compositing.
// Used for committed previews and tests; Apple builds draw the same list on the GPU.
import Foundation

public struct Image2D: Sendable {
    public let width: Int
    public let height: Int
    public var rgb: [Float]   // linear in sRGB code values, 0…1

    public init(width: Int, height: Int, background: RGBA) {
        self.width = width; self.height = height
        rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[3 * i] = Float(background.r); rgb[3 * i + 1] = Float(background.g); rgb[3 * i + 2] = Float(background.b)
        }
    }

    public func pixel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let i = 3 * (y * width + x)
        return (rgb[i], rgb[i + 1], rgb[i + 2])
    }

    public func bytes() -> [UInt8] {
        rgb.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
    }

    /// FNV-1a over 8-bit output, for determinism tests.
    public var hash: UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes() { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}

public enum Raster2D {
    static let subRows = 4

    public static func render(_ list: DrawList, width: Int, height: Int, background: RGBA = .black) -> Image2D {
        var img = Image2D(width: width, height: height, background: background)
        let sx = Double(width) / list.width, sy = Double(height) / list.height
        let toPx = Affine2.scale(sx, sy)
        let wScale = (sx * sy).squareRoot()
        var clips: [ClipShape] = []
        for cmd in list.commands {
            switch cmd {
            case let .fill(pts, c):
                fill(&img, contours: [pts.map(toPx.apply)], color: c, clips: clips)
            case let .stroke(pts, w, c):
                fill(&img, contours: strokeContours(pts.map(toPx.apply), halfWidth: max(0.35, w * wScale / 2)), color: c, clips: clips)
            case let .pushClip(shape):
                switch shape {
                case let .rect(x0, y0, x1, y1):
                    clips.append(.rect(minX: x0 * sx, minY: y0 * sy, maxX: x1 * sx, maxY: y1 * sy))
                case let .circle(c, r):
                    clips.append(.circle(center: toPx.apply(c), radius: r * wScale))
                }
            case .popClip:
                _ = clips.popLast()
            }
        }
        return img
    }

    /// Round-capped, round-joined stroke as positively oriented contours (union under non-zero).
    static func strokeContours(_ pts: [Point2], halfWidth hw: Double) -> [[Point2]] {
        var out: [[Point2]] = []
        let segs = max(8, min(40, Int(hw * 3)))
        func disc(_ c: Point2) -> [Point2] {
            (0..<segs).map { i in
                let a = Double(i) / Double(segs) * 2 * .pi
                return Point2(c.x + hw * cos(a), c.y + hw * sin(a))
            }
        }
        for p in pts { out.append(disc(p)) }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let d = b - a
            let len = d.length
            guard len > 1e-9 else { continue }
            let n = Point2(-d.y / len * hw, d.x / len * hw)
            out.append([a - n, b - n, b + n, a + n])
        }
        return out
    }

    private struct Edge { var x0, y0, x1, y1: Double; var dir: Int }

    static func fill(_ img: inout Image2D, contours: [[Point2]], color: RGBA, clips: [ClipShape]) {
        var edges: [Edge] = []
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for poly in contours where poly.count >= 3 {
            // Normalize each contour to the same orientation so overlapping pieces union.
            var area = 0.0
            for i in 0..<poly.count {
                let p = poly[i], q = poly[(i + 1) % poly.count]
                area += p.x * q.y - q.x * p.y
            }
            let flip = contours.count > 1 && area < 0
            for i in 0..<poly.count {
                let p = poly[i], q = poly[(i + 1) % poly.count]
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
                if p.y == q.y { continue }
                var dir = p.y < q.y ? 1 : -1
                if flip { dir = -dir }
                edges.append(p.y < q.y ? Edge(x0: p.x, y0: p.y, x1: q.x, y1: q.y, dir: dir)
                                       : Edge(x0: q.x, y0: q.y, x1: p.x, y1: p.y, dir: dir))
            }
        }
        guard !edges.isEmpty else { return }
        let w = img.width
        let y0 = max(0, Int(floor(minY))), y1 = min(img.height - 1, Int(ceil(maxY)))
        let px0 = max(0, Int(floor(minX))), px1 = min(w - 1, Int(ceil(maxX)))
        guard y0 <= y1, px0 <= px1 else { return }
        edges.sort { $0.y0 < $1.y0 }
        var cov = [Double](repeating: 0, count: px1 - px0 + 2)
        var xs: [(Double, Int)] = []
        xs.reserveCapacity(64)
        let alpha = color.a
        let cr = Float(color.r), cg = Float(color.g), cb = Float(color.b)
        let inv = 1.0 / Double(subRows)
        for y in y0...y1 {
            for i in cov.indices { cov[i] = 0 }
            var any = false
            for s in 0..<subRows {
                let yy = Double(y) + (Double(s) + 0.5) * inv
                var lo = -Double.infinity, hi = Double.infinity
                var clipped = false
                for c in clips {
                    guard let (a, b) = c.span(atY: yy) else { clipped = true; break }
                    lo = max(lo, a); hi = min(hi, b)
                }
                if clipped || lo >= hi { continue }
                xs.removeAll(keepingCapacity: true)
                for e in edges {
                    if e.y0 > yy { break }
                    if yy >= e.y1 { continue }
                    let t = (yy - e.y0) / (e.y1 - e.y0)
                    xs.append((e.x0 + t * (e.x1 - e.x0), e.dir))
                }
                if xs.count < 2 { continue }
                xs.sort { $0.0 < $1.0 }
                var wind = 0
                var spanStart = 0.0
                for (x, d) in xs {
                    let was = wind
                    wind += d
                    if was == 0 && wind != 0 { spanStart = x }
                    else if was != 0 && wind == 0 {
                        let a = max(spanStart, lo, Double(px0)), b = min(x, hi, Double(px1 + 1))
                        if a < b { addSpan(&cov, a - Double(px0), b - Double(px0), inv); any = true }
                    }
                }
            }
            guard any else { continue }
            let row = y * w
            for i in 0..<(px1 - px0 + 1) {
                let c = min(1, cov[i]) * alpha
                if c <= 0.0005 { continue }
                let k = 3 * (row + px0 + i)
                let fc = Float(c), fi = Float(1 - c)
                img.rgb[k] = img.rgb[k] * fi + cr * fc
                img.rgb[k + 1] = img.rgb[k + 1] * fi + cg * fc
                img.rgb[k + 2] = img.rgb[k + 2] * fi + cb * fc
            }
        }
    }

    @inline(__always)
    private static func addSpan(_ cov: inout [Double], _ a: Double, _ b: Double, _ weight: Double) {
        let ia = Int(floor(a)), ib = Int(floor(b))
        if ia == ib { cov[ia] += (b - a) * weight; return }
        cov[ia] += (Double(ia + 1) - a) * weight
        if ia + 1 < ib { for i in (ia + 1)..<ib { cov[i] += weight } }
        if ib < cov.count { cov[ib] += (b - Double(ib)) * weight }
    }
}
