// SKYFORGE — Apache-2.0
// RFC 1950/1951 zlib + DEFLATE decoder (stored, fixed and dynamic Huffman blocks). Pure Swift.

public enum InflateError: Error, Equatable {
    case truncated
    case badHeader
    case badBlockType
    case badStoredLength
    case badCode
    case badDistance
    case checksumMismatch
    case outputTooLarge
    case oversubscribed
}

struct BitReader {
    let data: [UInt8]
    var pos = 0
    var bitBuf: UInt32 = 0
    var bitCount = 0

    init(_ data: [UInt8], start: Int) { self.data = data; pos = start }

    mutating func need(_ n: Int) throws {
        while bitCount < n {
            guard pos < data.count else { throw InflateError.truncated }
            bitBuf |= UInt32(data[pos]) << UInt32(bitCount)
            pos += 1
            bitCount += 8
        }
    }
    mutating func bits(_ n: Int) throws -> Int {
        if n == 0 { return 0 }
        try need(n)
        let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
        bitBuf >>= UInt32(n)
        bitCount -= n
        return v
    }
    /// Tops the bit buffer up to at least `n` bits when input remains; never throws (end of data just leaves fewer).
    mutating func fill(_ n: Int) {
        while bitCount < n, pos < data.count {
            bitBuf |= UInt32(data[pos]) << UInt32(bitCount)
            pos += 1
            bitCount += 8
        }
    }
    mutating func alignToByte() { pos -= bitCount / 8; bitBuf = 0; bitCount = 0 }
}

/// Canonical Huffman decoding table (counts per length + symbols sorted by code).
struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]
    /// Lookup indexed by the next `fastBits` stream bits (LSB first): symbol | length << 9, 0 = use slow path.
    var fast = [UInt16](repeating: 0, count: 1 << Huffman.fastBits)
    static let fastBits = 9

    init(lengths: [Int]) throws {
        symbols = [Int](repeating: 0, count: lengths.count)
        for l in lengths {
            guard l >= 0, l < 16 else { throw InflateError.badCode }
            counts[l] += 1
        }
        counts[0] = 0
        var left = 1
        for len in 1..<16 {
            left <<= 1
            left -= counts[len]
            if left < 0 { throw InflateError.oversubscribed }
        }
        var offs = [Int](repeating: 0, count: 16)
        for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
        for (sym, l) in lengths.enumerated() where l != 0 {
            symbols[offs[l]] = sym
            offs[l] += 1
        }
        // Canonical codes (RFC 1951 3.2.2); codes are MSB-first in the stream, so index by the reversed code.
        var next = [Int](repeating: 0, count: 17)
        var code = 0
        for l in 1..<16 { code = (code + counts[l - 1]) << 1; next[l] = code }
        for (sym, l) in lengths.enumerated() where l != 0 && l <= Huffman.fastBits {
            let c = next[l]
            next[l] += 1
            guard c < (1 << l) else { continue }   // over-subscribed: leave to the slow path
            var rev = 0
            for b in 0..<l where c & (1 << b) != 0 { rev |= 1 << (l - 1 - b) }
            let entry = UInt16(sym | l << 9)
            var idx = rev
            while idx < (1 << Huffman.fastBits) { fast[idx] = entry; idx += 1 << l }
        }
    }

    func decode(_ r: inout BitReader) throws -> Int {
        r.fill(Huffman.fastBits)
        let e = Int(fast[Int(r.bitBuf) & ((1 << Huffman.fastBits) - 1)])
        if e != 0 {
            let l = e >> 9
            if l <= r.bitCount {
                r.bitBuf >>= UInt32(l)
                r.bitCount -= l
                return e & 0x1FF
            }
        }
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try r.bits(1)
            let count = counts[len]
            if code - count < first {
                let si = index + (code - first)
                guard si >= 0, si < symbols.count else { throw InflateError.badCode }
                return symbols[si]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw InflateError.badCode
    }
}

public enum Inflate {
    /// Hard cap on decompressed output (hostile-input guard).
    public static let maxOutputSize = 256 << 20

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Decompresses a zlib stream (2-byte header, deflate data, Adler-32 trailer).
    public static func zlib(_ input: [UInt8], expectedSize: Int = 0, maxOutput: Int = Inflate.maxOutputSize) throws -> [UInt8] {
        guard input.count >= 6 else { throw InflateError.truncated }
        let cmf = Int(input[0]), flg = Int(input[1])
        guard cmf & 0x0F == 8, (cmf << 8 | flg) % 31 == 0, flg & 0x20 == 0 else { throw InflateError.badHeader }
        var r = BitReader(input, start: 2)
        let out = try inflate(&r, expectedSize: min(expectedSize, maxOutput), maxOutput: maxOutput)
        let p = r.pos - r.bitCount / 8
        if p + 4 <= input.count {
            let adler = UInt32(input[p]) << 24 | UInt32(input[p + 1]) << 16 | UInt32(input[p + 2]) << 8 | UInt32(input[p + 3])
            guard adler == adler32(out) else { throw InflateError.checksumMismatch }
        }
        return out
    }

    static func adler32(_ d: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0, i = 0
        while i < d.count {
            let end = min(i + 5552, d.count)
            while i < end { a += UInt32(d[i]); b += a; i += 1 }
            a %= 65521; b %= 65521
        }
        return b << 16 | a
    }

    static func inflate(_ r: inout BitReader, expectedSize: Int, maxOutput: Int = Inflate.maxOutputSize) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(max(min(expectedSize, maxOutput, 64 * 1024 * 1024), 1024))
        let fixedLit: Huffman = try {
            var l = [Int](repeating: 8, count: 288)
            for i in 144..<256 { l[i] = 9 }
            for i in 256..<280 { l[i] = 7 }
            return try Huffman(lengths: l)
        }()
        let fixedDist = try Huffman(lengths: [Int](repeating: 5, count: 30))
        var final = 0
        repeat {
            final = try r.bits(1)
            let type = try r.bits(2)
            switch type {
            case 0:
                r.alignToByte()
                guard r.pos + 4 <= r.data.count else { throw InflateError.truncated }
                let len = Int(r.data[r.pos]) | Int(r.data[r.pos + 1]) << 8
                let nlen = Int(r.data[r.pos + 2]) | Int(r.data[r.pos + 3]) << 8
                guard len == (~nlen & 0xFFFF) else { throw InflateError.badStoredLength }
                r.pos += 4
                guard r.pos + len <= r.data.count else { throw InflateError.truncated }
                guard out.count + len <= maxOutput else { throw InflateError.outputTooLarge }
                out.append(contentsOf: r.data[r.pos..<(r.pos + len)])
                r.pos += len
            case 1:
                try codes(&r, &out, fixedLit, fixedDist, maxOutput)
            case 2:
                let hlit = try r.bits(5) + 257, hdist = try r.bits(5) + 1, hclen = try r.bits(4) + 4
                guard hlit <= 286, hdist <= 30 else { throw InflateError.badCode }
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<hclen { cl[clOrder[i]] = try r.bits(3) }
                let clh = try Huffman(lengths: cl)
                var lengths = [Int]()
                while lengths.count < hlit + hdist {
                    let sym = try clh.decode(&r)
                    guard lengths.count < 400 else { throw InflateError.badCode }
                    switch sym {
                    case 0..<16: lengths.append(sym)
                    case 16:
                        guard let last = lengths.last else { throw InflateError.badCode }
                        lengths += [Int](repeating: last, count: 3 + (try r.bits(2)))
                    case 17: lengths += [Int](repeating: 0, count: 3 + (try r.bits(3)))
                    default: lengths += [Int](repeating: 0, count: 11 + (try r.bits(7)))
                    }
                }
                guard lengths.count == hlit + hdist else { throw InflateError.badCode }
                let lit = try Huffman(lengths: Array(lengths[0..<hlit]))
                let dist = try Huffman(lengths: Array(lengths[hlit...]))
                try codes(&r, &out, lit, dist, maxOutput)
            default:
                throw InflateError.badBlockType
            }
        } while final == 0
        return out
    }

    static func codes(_ r: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman, _ maxOutput: Int) throws {
        while true {
            let sym = try lit.decode(&r)
            if sym < 256 {
                guard out.count < maxOutput else { throw InflateError.outputTooLarge }
                out.append(UInt8(sym)); continue }
            if sym == 256 { return }
            let li = sym - 257
            guard li < 29 else { throw InflateError.badCode }
            let len = lengthBase[li] + (try r.bits(lengthExtra[li]))
            let di = try dist.decode(&r)
            guard di < 30 else { throw InflateError.badDistance }
            let d = distBase[di] + (try r.bits(distExtra[di]))
            guard d <= out.count else { throw InflateError.badDistance }
            guard out.count + len <= maxOutput else { throw InflateError.outputTooLarge }
            let start = out.count - d
            for i in 0..<len { out.append(out[start + i]) }
        }
    }
}
