// SKYFORGE — Apache-2.0
// Visual regression (§8.7): image comparison metrics and golden-image checks. Used for CPU
// previews on every platform and for the offscreen Metal renderer wherever a device exists.
import Foundation
import SFTerrainCore

public struct ImageDiff: Sendable, Equatable {
    public var meanAbsError: Double        // 0…255, over all RGB samples
    public var maxAbsError: Int            // 0…255
    public var fractionOver: Double        // pixels whose max channel error exceeds the pixel threshold
    public var ssim: Double                // luminance SSIM over 8×8 windows, 1 = identical

    public struct Tolerance: Sendable, Equatable {
        public var meanAbsError: Double
        public var pixelThreshold: Int
        public var fractionOver: Double
        public var minSSIM: Double
        public init(meanAbsError: Double = 1.5, pixelThreshold: Int = 24, fractionOver: Double = 0.002, minSSIM: Double = 0.98) {
            self.meanAbsError = meanAbsError; self.pixelThreshold = pixelThreshold
            self.fractionOver = fractionOver; self.minSSIM = minSSIM
        }
        public static let exact = Tolerance(meanAbsError: 0, pixelThreshold: 0, fractionOver: 0, minSSIM: 1)
    }

    public func passes(_ t: Tolerance) -> Bool {
        meanAbsError <= t.meanAbsError && fractionOver <= t.fractionOver && ssim >= t.minSSIM - 1e-12
    }

    /// Compares two RGB8 images of equal size.
    public static func compare(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int, pixelThreshold: Int = 24) -> ImageDiff {
        precondition(a.count == w * h * 3 && b.count == w * h * 3, "image sizes differ")
        var sum = 0, mx = 0, over = 0
        for p in 0..<(w * h) {
            var pm = 0
            for c in 0..<3 {
                let d = abs(Int(a[3 * p + c]) - Int(b[3 * p + c]))
                sum += d; pm = max(pm, d)
            }
            mx = max(mx, pm)
            if pm > pixelThreshold { over += 1 }
        }
        return ImageDiff(meanAbsError: Double(sum) / Double(max(1, w * h * 3)), maxAbsError: mx,
                         fractionOver: Double(over) / Double(max(1, w * h)), ssim: ssim(a, b, w, h))
    }

    static func luma(_ img: [UInt8], _ w: Int, _ h: Int) -> [Double] {
        var out = [Double](repeating: 0, count: w * h)
        for p in 0..<(w * h) {
            let r = Double(img[3 * p]), g = Double(img[3 * p + 1]), b = Double(img[3 * p + 2])
            out[p] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return out
    }

    static func ssim(_ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int) -> Double {
        let la = luma(a, w, h), lb = luma(b, w, h)
        let c1: Double = 6.5025, c2: Double = 58.5225   // (0.01·255)², (0.03·255)²
        let win = 8
        var total = 0.0, n = 0
        var y = 0
        while y + win <= h {
            var x = 0
            while x + win <= w {
                var ma = 0.0, mb = 0.0
                for j in 0..<win { for i in 0..<win { ma += la[(y + j) * w + x + i]; mb += lb[(y + j) * w + x + i] } }
                let k = Double(win * win)
                ma /= k; mb /= k
                var va = 0.0, vb = 0.0, cov = 0.0
                for j in 0..<win {
                    for i in 0..<win {
                        let da = la[(y + j) * w + x + i] - ma, db = lb[(y + j) * w + x + i] - mb
                        va += da * da; vb += db * db; cov += da * db
                    }
                }
                va /= k - 1; vb /= k - 1; cov /= k - 1
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                n += 1
                x += win
            }
            y += win
        }
        return n == 0 ? 1 : total / Double(n)
    }

    /// Amplified absolute-difference image for humans (×8, clamped).
    public static func heatmap(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        zip(a, b).map { UInt8(min(255, abs(Int($0) - Int($1)) * 8)) }
    }
}

public enum VisualRegression {
    public enum Outcome: Sendable, Equatable {
        case passed(ImageDiff)
        case failed(ImageDiff, artefacts: [String])
        case blessed(String)          // golden written (SKYFORGE_BLESS=1)
        case missingGolden(String)    // candidate written; commit it after review
    }

    /// Compares an RGB8 image with `<goldenDir>/<name>.png`. On failure or a missing golden, writes
    /// `<name>.actual.png` (and `<name>.diff.png`) to `SKYFORGE_VISUAL_OUT` or the temp directory.
    public static func check(name: String, rgb: [UInt8], width: Int, height: Int, goldenDir: URL,
                             tolerance: ImageDiff.Tolerance = .init(),
                             environment env: [String: String] = ProcessInfo.processInfo.environment) -> Outcome {
        let golden = goldenDir.appendingPathComponent(name + ".png")
        let out = URL(fileURLWithPath: env["SKYFORGE_VISUAL_OUT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("skyforge-visual").path)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let png = PNGEncoder.encodeRGB(width: width, height: height, rgb: rgb)
        guard let data = try? Data(contentsOf: golden), let g = try? PNGDecoder.decode([UInt8](data)),
              g.width == width, g.height == height else {
            if env["SKYFORGE_BLESS"] == "1" {
                try? FileManager.default.createDirectory(at: goldenDir, withIntermediateDirectories: true)
                try? png.write(to: golden)
                return .blessed(golden.path)
            }
            let cand = out.appendingPathComponent(name + ".actual.png")
            try? png.write(to: cand)
            return .missingGolden(cand.path)
        }
        let ref = rgbFrom(g)
        let d = ImageDiff.compare(rgb, ref, width: width, height: height, pixelThreshold: tolerance.pixelThreshold)
        if d.passes(tolerance) { return .passed(d) }
        let actual = out.appendingPathComponent(name + ".actual.png")
        let diff = out.appendingPathComponent(name + ".diff.png")
        try? png.write(to: actual)
        try? PNGEncoder.encodeRGB(width: width, height: height, rgb: ImageDiff.heatmap(rgb, ref)).write(to: diff)
        return .failed(d, artefacts: [actual.path, diff.path])
    }

    static func rgbFrom(_ g: DecodedImage) -> [UInt8] {
        if g.channels == 3 { return g.pixels }
        var out = [UInt8](); out.reserveCapacity(g.width * g.height * 3)
        for p in 0..<(g.width * g.height) {
            switch g.channels {
            case 4: out += [g.pixels[4 * p], g.pixels[4 * p + 1], g.pixels[4 * p + 2]]
            case 1: out += [g.pixels[p], g.pixels[p], g.pixels[p]]
            case 2: out += [g.pixels[2 * p], g.pixels[2 * p], g.pixels[2 * p]]
            default: out += [0, 0, 0]
            }
        }
        return out
    }
}
