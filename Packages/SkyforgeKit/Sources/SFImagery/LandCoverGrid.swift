// SKYFORGE — Apache-2.0
// Land cover classes on a local metre grid around an airport (ESA WorldCover 2021 v200, CC BY 4.0,
// written by `tools/fetch_landcover.py`). Used for what a photo's colour cannot decide reliably:
// where water is (lakes, sea, wide rivers), at any distance from the field.
import Foundation
import SFTerrainCore

public struct LandCoverGrid: Sendable {
    public static let attribution = "Land cover: © ESA WorldCover project 2021 (contains modified Copernicus Sentinel data), CC BY 4.0"
    public static let fileName = "landcover.png"
    /// WorldCover class codes.
    public static let tree: UInt8 = 10, shrub: UInt8 = 20, grass: UInt8 = 30, crop: UInt8 = 40, built: UInt8 = 50
    public static let bare: UInt8 = 60, snow: UInt8 = 70, water: UInt8 = 80, wetland: UInt8 = 90, moss: UInt8 = 100

    public let size: Int
    /// The grid covers ±halfExtent metres east and north of the origin; row 0 is the north edge.
    public let halfExtent: Double
    public let classes: [UInt8]

    public init(size: Int, halfExtent: Double, classes: [UInt8]) {
        precondition(classes.count == size * size)
        self.size = size; self.halfExtent = halfExtent; self.classes = classes
    }

    /// Decodes the greyscale PNG `fetch_landcover.py` writes (nil when it is not one).
    public init?(png: Data, halfExtent: Double = 40_000) {
        guard let img = try? PNGDecoder.decode([UInt8](png)), img.channels == 1, img.width == img.height, img.width > 1 else { return nil }
        self.init(size: img.width, halfExtent: halfExtent, classes: img.pixels)
    }

    public var metresPerCell: Double { 2 * halfExtent / Double(size) }

    @inline(__always) func wet(_ i: Int, _ j: Int) -> Float {
        let c = classes[min(size - 1, max(0, j)) * size + min(size - 1, max(0, i))]
        return c == Self.water || c == 0 ? 1 : 0      // no data in WorldCover is open ocean
    }

    /// Class at a point (0 outside the grid).
    public func cls(_ x: Double, _ y: Double) -> UInt8 {
        let i = Int(((x + halfExtent) / metresPerCell).rounded(.down)), j = Int(((halfExtent - y) / metresPerCell).rounded(.down))
        guard i >= 0, j >= 0, i < size, j < size else { return 0 }
        return classes[j * size + i]
    }

    public func contains(_ x: Double, _ y: Double) -> Bool { abs(x) < halfExtent && abs(y) < halfExtent }

    /// Water fraction at a point, bilinear between cell centres (0 outside the grid).
    public func water(_ x: Double, _ y: Double) -> Float {
        guard contains(x, y) else { return 0 }
        let fx = (x + halfExtent) / metresPerCell - 0.5, fy = (halfExtent - y) / metresPerCell - 0.5
        let i = Int(fx.rounded(.down)), j = Int(fy.rounded(.down))
        let ax = Float(fx - Double(i)), ay = Float(fy - Double(j))
        let a = wet(i, j), b = wet(i + 1, j), c = wet(i, j + 1), d = wet(i + 1, j + 1)
        return (a + (b - a) * ax) * (1 - ay) + (c + (d - c) * ax) * ay
    }

    /// Least and greatest water value over the 3 × 3 cells around a point: (1, 1) is open water,
    /// (0, 0) is land with no water within a cell, anything else is a shoreline.
    public func waterRange(_ x: Double, _ y: Double) -> (min: Float, max: Float) {
        guard contains(x, y) else { return (0, 0) }
        let i = Int(((x + halfExtent) / metresPerCell).rounded(.down)), j = Int(((halfExtent - y) / metresPerCell).rounded(.down))
        var lo: Float = 1, hi: Float = 0
        for dj in -1...1 { for di in -1...1 { let w = wet(i + di, j + dj); lo = min(lo, w); hi = max(hi, w) } }
        return (lo, hi)
    }
}
