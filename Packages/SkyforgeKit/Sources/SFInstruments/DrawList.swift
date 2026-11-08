// SKYFORGE — Apache-2.0
// Platform-neutral 2D display list for instruments (§12: steam gauges and the SF-1000 PFD).
// Builders emit device-space primitives; the CPU rasterizer (previews, tests) and the
// SwiftUI Canvas / Metal 2D paths on Apple consume the same list.
import Foundation

public struct Point2: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static func + (a: Point2, b: Point2) -> Point2 { Point2(a.x + b.x, a.y + b.y) }
    public static func - (a: Point2, b: Point2) -> Point2 { Point2(a.x - b.x, a.y - b.y) }
    public static func * (a: Point2, s: Double) -> Point2 { Point2(a.x * s, a.y * s) }
    public var length: Double { (x * x + y * y).squareRoot() }
}

/// sRGB colour with straight alpha, components 0…1.
public struct RGBA: Sendable, Equatable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
    }
    public func withAlpha(_ a: Double) -> RGBA { RGBA(r, g, b, a) }
    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
}

/// Affine map: p' = (a x + c y + tx, b x + d y + ty).
public struct Affine2: Sendable, Equatable {
    public var a, b, c, d, tx, ty: Double
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = Affine2(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public func apply(_ p: Point2) -> Point2 { Point2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }
    /// self ∘ m (m applied first).
    public func concat(_ m: Affine2) -> Affine2 {
        Affine2(a: a * m.a + c * m.b, b: b * m.a + d * m.b,
                c: a * m.c + c * m.d, d: b * m.c + d * m.d,
                tx: a * m.tx + c * m.ty + tx, ty: b * m.tx + d * m.ty + ty)
    }
    public static func translate(_ x: Double, _ y: Double) -> Affine2 { Affine2(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    public static func scale(_ sx: Double, _ sy: Double) -> Affine2 { Affine2(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0) }
    /// Counter-clockwise rotation in a y-up frame.
    public static func rotate(_ r: Double) -> Affine2 { Affine2(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), tx: 0, ty: 0) }
    /// Mean linear scale (for stroke widths).
    public var scaleFactor: Double { (abs(a * d - b * c)).squareRoot() }
}

public enum ClipShape: Sendable, Equatable {
    case rect(minX: Double, minY: Double, maxX: Double, maxY: Double)
    case circle(center: Point2, radius: Double)

    /// Horizontal extent of the clip at device row y (nil when the row is outside).
    public func span(atY y: Double) -> (Double, Double)? {
        switch self {
        case let .rect(x0, y0, x1, y1):
            return (y >= y0 && y < y1) ? (x0, x1) : nil
        case let .circle(c, r):
            let dy = y - c.y
            guard abs(dy) < r else { return nil }
            let h = (r * r - dy * dy).squareRoot()
            return (c.x - h, c.x + h)
        }
    }
}

public enum DrawCommand: Sendable, Equatable {
    /// Filled polygon (non-zero winding), device coordinates.
    case fill([Point2], RGBA)
    /// Polyline stroke with round joins and caps, device coordinates.
    case stroke([Point2], width: Double, RGBA)
    case pushClip(ClipShape)
    case popClip
}

public struct DrawList: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var commands: [DrawCommand] = []
    public init(width: Double, height: Double) { self.width = width; self.height = height }

    public var primitiveCount: Int {
        commands.reduce(0) { n, c in
            switch c { case .fill, .stroke: return n + 1; default: return n }
        }
    }
    public mutating func append(_ other: DrawList) { commands += other.commands }
}

/// Immediate-mode builder with a transform stack. Builder space is y-up, so instrument
/// code reads like math; the base transform flips into y-down device pixels.
public struct DrawBuilder {
    public private(set) var list: DrawList
    public var transform: Affine2
    private var stack: [Affine2] = []

    public init(width: Double, height: Double) {
        list = DrawList(width: width, height: height)
        transform = Affine2(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    public mutating func save() { stack.append(transform) }
    public mutating func restore() { transform = stack.popLast() ?? transform }
    public mutating func translate(_ x: Double, _ y: Double) { transform = transform.concat(.translate(x, y)) }
    public mutating func scale(_ s: Double) { transform = transform.concat(.scale(s, s)) }
    /// Rotate counter-clockwise (radians) in builder space.
    public mutating func rotate(_ r: Double) { transform = transform.concat(.rotate(r)) }

    public mutating func fill(_ pts: [Point2], _ color: RGBA) {
        guard pts.count >= 3, color.a > 0 else { return }
        list.commands.append(.fill(pts.map(transform.apply), color))
    }
    public mutating func stroke(_ pts: [Point2], width: Double, _ color: RGBA) {
        guard pts.count >= 2, color.a > 0 else { return }
        list.commands.append(.stroke(pts.map(transform.apply), width: width * transform.scaleFactor, color))
    }
    public mutating func line(_ a: Point2, _ b: Point2, width: Double, _ color: RGBA) { stroke([a, b], width: width, color) }

    public mutating func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ color: RGBA) {
        fill([Point2(x0, y0), Point2(x1, y0), Point2(x1, y1), Point2(x0, y1)], color)
    }
    public mutating func rectOutline(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, width: Double, _ color: RGBA) {
        stroke([Point2(x0, y0), Point2(x1, y0), Point2(x1, y1), Point2(x0, y1), Point2(x0, y0)], width: width, color)
    }

    public static func arcPoints(center: Point2, radius: Double, from a0: Double, to a1: Double, segments: Int? = nil) -> [Point2] {
        let n = segments ?? max(8, Int(abs(a1 - a0) / (2 * .pi) * 96))
        return (0...n).map { i in
            let a = a0 + (a1 - a0) * Double(i) / Double(n)
            return Point2(center.x + radius * cos(a), center.y + radius * sin(a))
        }
    }
    public mutating func circle(_ c: Point2, _ r: Double, _ color: RGBA) {
        var pts = Self.arcPoints(center: c, radius: r, from: 0, to: 2 * .pi)
        pts.removeLast()
        fill(pts, color)
    }
    public mutating func ring(_ c: Point2, inner: Double, outer: Double, from a0: Double = 0, to a1: Double = 2 * .pi, _ color: RGBA) {
        let o = Self.arcPoints(center: c, radius: outer, from: a0, to: a1)
        let i = Self.arcPoints(center: c, radius: inner, from: a1, to: a0, segments: o.count - 1)
        fill(o + i, color)
    }

    /// Clip in builder space. Circles stay circles under similarity transforms; rects must
    /// be axis-aligned after transform (no rotation on the stack), which callers respect.
    public mutating func pushClipCircle(_ c: Point2, _ r: Double) {
        list.commands.append(.pushClip(.circle(center: transform.apply(c), radius: r * transform.scaleFactor)))
    }
    public mutating func pushClipRect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
        let p = transform.apply(Point2(x0, y0)), q = transform.apply(Point2(x1, y1))
        list.commands.append(.pushClip(.rect(minX: min(p.x, q.x), minY: min(p.y, q.y), maxX: max(p.x, q.x), maxY: max(p.y, q.y))))
    }
    public mutating func popClip() { list.commands.append(.popClip) }

    // MARK: text

    public enum Align: Sendable { case left, center, right }

    /// Stroke-font text. `size` is the cap height in builder units; (x, y) is the baseline anchor.
    public mutating func text(_ s: String, at p: Point2, size: Double, align: Align = .center,
                              weight: Double = 0.13, _ color: RGBA) {
        let unit = size / 6
        let w = StrokeFont.width(of: s) * unit
        var x = p.x
        switch align {
        case .left: break
        case .center: x -= w / 2
        case .right: x -= w
        }
        for ch in s.uppercased() {
            for poly in StrokeFont.glyph(ch) {
                stroke(poly.map { Point2(x + $0.x * unit, p.y + $0.y * unit) }, width: size * weight, color)
            }
            x += StrokeFont.advance(for: ch) * unit
        }
    }
}
