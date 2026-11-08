// SKYFORGE — Apache-2.0
// Baseline (sequential, Huffman, 8-bit) JPEG decoder in pure Swift, for imagery tiles on every
// platform (Linux previews and tests; Apple builds may use ImageIO instead). Supports 1 or 3
// components, any H/V sampling up to 4, restart intervals. Progressive/arithmetic are rejected.
import Foundation

public enum JPEGError: Error, Equatable {
    case notJPEG, unsupported(String), corrupt(String)
}

public struct RGBImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var rgb: [UInt8]
    public init(width: Int, height: Int, rgb: [UInt8]) { self.width = width; self.height = height; self.rgb = rgb }
    @inline(__always) public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = 3 * (y * width + x); return (rgb[i], rgb[i + 1], rgb[i + 2])
    }
}

public enum JPEGDecoder {
    struct Huffman {
        var lookup = [UInt16](repeating: 0, count: 1 << 9)   // fast 9-bit table: (len << 8) | value, 0 = miss
        var maxCode = [Int](repeating: -1, count: 18)
        var valPtr = [Int](repeating: 0, count: 17)
        var minCode = [Int](repeating: 0, count: 17)
        var values: [UInt8] = []

        init(counts: [UInt8], values v: [UInt8]) throws {
            values = v
            var code = 0, k = 0
            for len in 1...16 {
                valPtr[len] = k
                minCode[len] = code
                code += Int(counts[len - 1])
                k += Int(counts[len - 1])
                maxCode[len] = counts[len - 1] > 0 ? code - 1 : -1
                if len <= 9 {
                    for i in 0..<Int(counts[len - 1]) {
                        let c = minCode[len] + i
                        let shift = 9 - len
                        for fill in 0..<(1 << shift) {
                            lookup[(c << shift) | fill] = UInt16(len << 8) | UInt16(values[valPtr[len] + i])
                        }
                    }
                }
                code <<= 1
            }
            guard k == v.count else { throw JPEGError.corrupt("huffman table size") }
        }
    }

    struct BitReader {
        let data: [UInt8]
        var pos: Int
        var bits: UInt32 = 0
        var count = 0
        var hitMarker = false

        init(_ d: [UInt8], _ p: Int) { data = d; pos = p }

        @inline(__always) mutating func fill() {
            while count <= 24 {
                var byte: UInt32 = 0
                if !hitMarker && pos < data.count {
                    let b = data[pos]
                    if b == 0xFF {
                        let next = pos + 1 < data.count ? data[pos + 1] : 0
                        if next == 0x00 { byte = 0xFF; pos += 2 }
                        else { hitMarker = true }
                    } else { byte = UInt32(b); pos += 1 }
                }
                bits |= byte << UInt32(24 - count)
                count += 8
            }
        }
        @inline(__always) mutating func peek(_ n: Int) -> Int { fill(); return Int(bits >> UInt32(32 - n)) }
        @inline(__always) mutating func skip(_ n: Int) { bits <<= UInt32(n); count -= n }
        @inline(__always) mutating func get(_ n: Int) -> Int { if n == 0 { return 0 }; let v = peek(n); skip(n); return v }

        mutating func decode(_ h: Huffman) throws -> Int {
            let p = peek(9)
            let e = h.lookup[p]
            if e != 0 { skip(Int(e >> 8)); return Int(e & 0xFF) }
            var code = get(9), len = 9
            while len < 16 {
                code = (code << 1) | get(1); len += 1
                if h.maxCode[len] >= 0 && code <= h.maxCode[len] && code >= h.minCode[len] {
                    return Int(h.values[h.valPtr[len] + code - h.minCode[len]])
                }
            }
            throw JPEGError.corrupt("bad huffman code")
        }
        @inline(__always) static func extend(_ v: Int, _ n: Int) -> Int { n == 0 ? 0 : (v < (1 << (n - 1)) ? v - (1 << n) + 1 : v) }

        /// Realigns after an RSTn marker.
        mutating func restart() {
            bits = 0; count = 0; hitMarker = false
            while pos + 1 < data.count && !(data[pos] == 0xFF && (0xD0...0xD7).contains(data[pos + 1])) { pos += 1 }
            pos += 2
        }
    }

    struct Component { var id: UInt8; var h: Int; var v: Int; var tq: Int; var td = 0; var ta = 0; var pred = 0; var plane: [UInt8] = []; var stride = 0 }

    static let zigzag: [Int] = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21,
                                28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61,
                                54, 47, 55, 62, 63]

    // Separable float IDCT with precomputed cosines (accuracy over speed; tiles are small).
    static let cosTable: [Float] = {
        var t = [Float](repeating: 0, count: 64)
        for x in 0..<8 { for u in 0..<8 {
            let cu: Float = u == 0 ? 1 / 2.0.squareRoot().asFloat : 1
            t[x * 8 + u] = cu * Float(cos(Double(2 * x + 1) * Double(u) * .pi / 16)) / 2
        } }
        return t
    }()

    static func idct(_ coef: inout [Float], _ out: inout [UInt8], _ base: Int, _ stride: Int) {
        var tmp = [Float](repeating: 0, count: 64)
        for y in 0..<8 { for x in 0..<8 {
            var s: Float = 0
            for u in 0..<8 { s += cosTable[x * 8 + u] * coef[y * 8 + u] }
            tmp[y * 8 + x] = s
        } }
        for x in 0..<8 { for y in 0..<8 {
            var s: Float = 0
            for v in 0..<8 { s += cosTable[y * 8 + v] * tmp[v * 8 + x] }
            out[base + y * stride + x] = UInt8(max(0, min(255, (s + 128).rounded())))
        } }
    }

    public static func decode(_ bytes: [UInt8]) throws -> RGBImage {
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw JPEGError.notJPEG }
        var qt = [[Int]](repeating: [Int](repeating: 1, count: 64), count: 4)
        var dcT = [Huffman?](repeating: nil, count: 4), acT = [Huffman?](repeating: nil, count: 4)
        var comps: [Component] = []
        var width = 0, height = 0, restartInterval = 0
        var pos = 2
        func be16(_ p: Int) -> Int { Int(bytes[p]) << 8 | Int(bytes[p + 1]) }
        while pos + 4 <= bytes.count {
            guard bytes[pos] == 0xFF else { pos += 1; continue }
            let marker = bytes[pos + 1]
            if marker == 0xFF { pos += 1; continue }
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) { pos += 2; continue }
            if marker == 0xD9 { break }
            let len = be16(pos + 2)
            let seg = pos + 4, end = pos + 2 + len
            guard end <= bytes.count else { throw JPEGError.corrupt("segment overruns") }
            switch marker {
            case 0xDB:
                var p = seg
                while p < end {
                    let pq = Int(bytes[p] >> 4), tq = Int(bytes[p] & 15); p += 1
                    guard tq < 4 else { throw JPEGError.corrupt("dqt id") }
                    for i in 0..<64 {
                        qt[tq][zigzag[i]] = pq == 0 ? Int(bytes[p]) : be16(p)
                        p += pq == 0 ? 1 : 2
                    }
                }
            case 0xC4:
                var p = seg
                while p < end {
                    let tc = Int(bytes[p] >> 4), th = Int(bytes[p] & 15); p += 1
                    guard th < 4 else { throw JPEGError.corrupt("dht id") }
                    let counts = Array(bytes[p..<(p + 16)]); p += 16
                    let n = counts.reduce(0) { $0 + Int($1) }
                    let vals = Array(bytes[p..<(p + n)]); p += n
                    let h = try Huffman(counts: counts, values: vals)
                    if tc == 0 { dcT[th] = h } else { acT[th] = h }
                }
            case 0xC0, 0xC1:
                guard bytes[seg] == 8 else { throw JPEGError.unsupported("precision \(bytes[seg])") }
                height = be16(seg + 1); width = be16(seg + 3)
                let nc = Int(bytes[seg + 5])
                guard nc == 1 || nc == 3 else { throw JPEGError.unsupported("\(nc) components") }
                for i in 0..<nc {
                    let b = seg + 6 + 3 * i
                    comps.append(Component(id: bytes[b], h: max(1, Int(bytes[b + 1] >> 4)), v: max(1, Int(bytes[b + 1] & 15)), tq: Int(bytes[b + 2] & 3)))
                }
            case 0xC2, 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                throw JPEGError.unsupported("non-baseline SOF \(String(marker, radix: 16))")
            case 0xDD:
                restartInterval = be16(seg)
            case 0xDA:
                guard width > 0, !comps.isEmpty else { throw JPEGError.corrupt("SOS before SOF") }
                let ns = Int(bytes[seg])
                for i in 0..<ns {
                    let cid = bytes[seg + 1 + 2 * i], t = bytes[seg + 2 + 2 * i]
                    guard let k = comps.firstIndex(where: { $0.id == cid }) else { throw JPEGError.corrupt("scan component") }
                    comps[k].td = Int(t >> 4); comps[k].ta = Int(t & 15)
                }
                let hmax = comps.map(\.h).max()!, vmax = comps.map(\.v).max()!
                let mcuW = 8 * hmax, mcuH = 8 * vmax
                let mcusX = (width + mcuW - 1) / mcuW, mcusY = (height + mcuH - 1) / mcuH
                for k in comps.indices {
                    comps[k].stride = mcusX * comps[k].h * 8
                    comps[k].plane = [UInt8](repeating: 0, count: comps[k].stride * mcusY * comps[k].v * 8)
                }
                var br = BitReader(bytes, end)
                var coef = [Float](repeating: 0, count: 64)
                var mcuCount = 0
                for my in 0..<mcusY {
                    for mx in 0..<mcusX {
                        if restartInterval > 0 && mcuCount > 0 && mcuCount % restartInterval == 0 {
                            br.restart()
                            for k in comps.indices { comps[k].pred = 0 }
                        }
                        mcuCount += 1
                        for k in comps.indices {
                            guard let dc = dcT[comps[k].td], let ac = acT[comps[k].ta] else { throw JPEGError.corrupt("missing huffman table") }
                            let q = qt[comps[k].tq]
                            for by in 0..<comps[k].v {
                                for bx in 0..<comps[k].h {
                                    for i in 0..<64 { coef[i] = 0 }
                                    let t = try br.decode(dc)
                                    comps[k].pred += BitReader.extend(br.get(t), t)
                                    coef[0] = Float(comps[k].pred * q[0])
                                    var i = 1
                                    while i < 64 {
                                        let rs = try br.decode(ac)
                                        let r = rs >> 4, s = rs & 15
                                        if s == 0 {
                                            if r == 15 { i += 16; continue }
                                            break
                                        }
                                        i += r
                                        guard i < 64 else { throw JPEGError.corrupt("coefficient overflow") }
                                        coef[zigzag[i]] = Float(BitReader.extend(br.get(s), s) * q[zigzag[i]])
                                        i += 1
                                    }
                                    let px = (mx * comps[k].h + bx) * 8, py = (my * comps[k].v + by) * 8
                                    idct(&coef, &comps[k].plane, py * comps[k].stride + px, comps[k].stride)
                                }
                            }
                        }
                    }
                }
                // Colour conversion with nearest-neighbour chroma upsampling.
                var rgb = [UInt8](repeating: 0, count: width * height * 3)
                for y in 0..<height {
                    for x in 0..<width {
                        func sample(_ c: Component) -> Float {
                            let sx = x * c.h / hmax, sy = y * c.v / vmax
                            return Float(c.plane[sy * c.stride + sx])
                        }
                        let o = 3 * (y * width + x)
                        if comps.count == 1 {
                            let g = UInt8(sample(comps[0])); rgb[o] = g; rgb[o + 1] = g; rgb[o + 2] = g
                        } else {
                            let Y = sample(comps[0]), cb = sample(comps[1]) - 128, cr = sample(comps[2]) - 128
                            rgb[o] = UInt8(max(0, min(255, (Y + 1.402 * cr).rounded())))
                            rgb[o + 1] = UInt8(max(0, min(255, (Y - 0.344136 * cb - 0.714136 * cr).rounded())))
                            rgb[o + 2] = UInt8(max(0, min(255, (Y + 1.772 * cb).rounded())))
                        }
                    }
                }
                return RGBImage(width: width, height: height, rgb: rgb)
            default:
                break
            }
            pos = end
        }
        throw JPEGError.corrupt("no scan")
    }
}

extension Double { var asFloat: Float { Float(self) } }
