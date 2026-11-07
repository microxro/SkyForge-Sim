// SKYFORGE — Apache-2.0
// METAR decoder (WMO FM 15 / FAA practice). Robust: unknown tokens are skipped, never fatal.
import Foundation
import SFMath

public struct Wind: Sendable, Equatable {
    public var directionDegrees: Int?      // nil = variable (VRB)
    public var speedKnots: Double
    public var gustKnots: Double?
    public var variableFrom: Int?
    public var variableTo: Int?
    public var isCalm: Bool { speedKnots == 0 && gustKnots == nil }
}

public enum CloudCover: String, Sendable, Equatable {
    case few = "FEW", scattered = "SCT", broken = "BKN", overcast = "OVC"
    /// Coverage fraction (oktas midpoint / 8).
    public var fraction: Double {
        switch self {
        case .few: return 1.5 / 8
        case .scattered: return 3.5 / 8
        case .broken: return 6 / 8
        case .overcast: return 1
        }
    }
}

public struct CloudLayer: Sendable, Equatable {
    public var cover: CloudCover
    public var baseFeet: Int?              // nil when reported as ///
    public var convective: String?         // "CB" or "TCU"
}

public struct RunwayVisualRange: Sendable, Equatable {
    public var runway: String
    public var metres: Int
}

public struct METAR: Sendable, Equatable {
    public var raw: String
    public var station: String
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var isAuto = false
    public var isCorrected = false
    public var isSpeci = false
    public var isNil = false
    public var wind: Wind?
    /// Prevailing visibility in metres (nil = not reported). 9999 / P6SM / CAVOK map to >= 10 km.
    public var visibilityMetres: Double?
    public var cavok = false
    public var rvr: [RunwayVisualRange] = []
    public var weather: [String] = []
    public var clouds: [CloudLayer] = []
    public var verticalVisibilityFeet: Int?
    public var skyClear = false
    public var temperatureC: Double?
    public var dewpointC: Double?
    /// Altimeter setting / QNH in hectopascals.
    public var qnhHectopascals: Double?
    public var altimeterWasInHg = false

    /// Lowest broken/overcast layer or vertical visibility (feet).
    public var ceilingFeet: Int? {
        if let vv = verticalVisibilityFeet { return vv }
        return clouds.filter { $0.cover == .broken || $0.cover == .overcast }.compactMap(\.baseFeet).min()
    }

    /// Flight category per FAA definitions.
    public var flightCategory: String {
        let visSM = (visibilityMetres ?? 10_000) / 1_609.344
        let ceil = ceilingFeet ?? 100_000
        if ceil < 500 || visSM < 1 { return "LIFR" }
        if ceil < 1_000 || visSM < 3 { return "IFR" }
        if ceil <= 3_000 || visSM <= 5 { return "MVFR" }
        return "VFR"
    }
}

public enum METARError: Error, Equatable {
    case empty
    case missingStation
    case missingTime
}

public enum METARParser {
    static let weatherCodes: Set<String> = ["DZ", "RA", "SN", "SG", "IC", "PL", "GR", "GS", "UP", "BR", "FG", "FU", "VA", "DU", "SA", "HZ", "PY", "PO", "SQ", "FC", "SS", "DS"]
    static let descriptors: Set<String> = ["MI", "PR", "BC", "DR", "BL", "SH", "TS", "FZ"]
    static let trendMarkers: Set<String> = ["RMK", "TEMPO", "BECMG", "NOSIG", "FM", "PROB30", "PROB40", "TREND"]

    public static func parse(_ text: String) throws -> METAR {
        var tokens = text.replacingOccurrences(of: "=", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { throw METARError.empty }
        var isSpeci = false
        if tokens.first == "METAR" || tokens.first == "SPECI" {
            isSpeci = tokens.removeFirst() == "SPECI"
        }
        if tokens.first == "COR" { tokens.removeFirst() }
        guard let station = tokens.first, station.count == 4, station.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw METARError.missingStation
        }
        tokens.removeFirst()
        guard let time = tokens.first, time.count == 7, time.hasSuffix("Z"),
              let day = Int(time.prefix(2)), let hour = Int(time.dropFirst(2).prefix(2)), let minute = Int(time.dropFirst(4).prefix(2)),
              (1...31).contains(day), (0...24).contains(hour), (0...59).contains(minute) else {
            throw METARError.missingTime
        }
        tokens.removeFirst()
        var m = METAR(raw: text.trimmingCharacters(in: .whitespacesAndNewlines), station: station, day: day, hour: hour, minute: minute)
        m.isSpeci = isSpeci
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if trendMarkers.contains(t) { break }
            defer { i += 1 }
            switch t {
            case "AUTO": m.isAuto = true; continue
            case "COR", "CCA": m.isCorrected = true; continue
            case "NIL": m.isNil = true; continue
            case "CAVOK":
                m.cavok = true; m.visibilityMetres = 10_000; continue
            case "SKC", "CLR", "NSC", "NCD":
                m.skyClear = true; continue
            default: break
            }
            if let w = parseWind(t) { m.wind = w; continue }
            if let (from, to) = parseVariableSector(t), m.wind != nil {
                m.wind?.variableFrom = from; m.wind?.variableTo = to; continue
            }
            // Visibility in statute miles, possibly split: "1 1/2SM"
            if t.hasSuffix("SM") {
                var whole = 0.0
                if i > 0, let w = Int(tokens[i - 1]), m.visibilityMetres == nil { whole = Double(w) }
                if let sm = parseStatuteMiles(String(t.dropLast(2))) { m.visibilityMetres = (whole + sm) * 1_609.344 }
                continue
            }
            if t.count == 4, let v = Int(t), m.visibilityMetres == nil, m.wind != nil || i <= 2 {
                m.visibilityMetres = v == 9999 ? 10_000 : Double(v); continue
            }
            if t.count == 1 || t.count == 2, Int(t) != nil, i + 1 < tokens.count, tokens[i + 1].hasSuffix("SM") {
                continue // whole-mile prefix handled with the next token
            }
            if t.hasPrefix("R"), t.contains("/"), let r = parseRVR(t) { m.rvr.append(r); continue }
            if t.hasPrefix("VV") {
                m.verticalVisibilityFeet = Int(t.dropFirst(2).prefix(3)).map { $0 * 100 }; continue
            }
            if let layer = parseCloud(t) { m.clouds.append(layer); continue }
            if let (tc, dc) = parseTempDew(t) { m.temperatureC = tc; m.dewpointC = dc; continue }
            if t.count == 5, t.hasPrefix("Q"), let q = Double(t.dropFirst()) { m.qnhHectopascals = q; continue }
            if t.count == 5, t.hasPrefix("A"), let a = Double(t.dropFirst()) {
                m.qnhHectopascals = a / 100 * 33.863_886; m.altimeterWasInHg = true; continue
            }
            if isWeather(t) { m.weather.append(t); continue }
        }
        return m
    }

    static func parseWind(_ t: String) -> Wind? {
        var unit = 1.0
        var body = Substring(t)
        if body.hasSuffix("KT") { body = body.dropLast(2) }
        else if body.hasSuffix("MPS") { body = body.dropLast(3); unit = 1.943_844 }
        else if body.hasSuffix("KMH") { body = body.dropLast(3); unit = 0.539_957 }
        else { return nil }
        guard body.count >= 5 else { return nil }
        let dirPart = body.prefix(3)
        var rest = body.dropFirst(3)
        var gust: Double?
        if let g = rest.firstIndex(of: "G") {
            gust = Double(rest[rest.index(after: g)...]).map { $0 * unit }
            rest = rest[..<g]
        }
        guard let speed = Double(rest) else { return nil }
        let dir: Int?
        if dirPart == "VRB" { dir = nil } else if let d = Int(dirPart), (0...360).contains(d) { dir = d } else { return nil }
        return Wind(directionDegrees: dir, speedKnots: speed * unit, gustKnots: gust)
    }

    static func parseVariableSector(_ t: String) -> (Int, Int)? {
        guard t.count == 7, t[t.index(t.startIndex, offsetBy: 3)] == "V",
              let a = Int(t.prefix(3)), let b = Int(t.suffix(3)) else { return nil }
        return (a, b)
    }

    static func parseStatuteMiles(_ s: String) -> Double? {
        var body = s
        if body.hasPrefix("P") || body.hasPrefix("M") { body.removeFirst() }
        if let slash = body.firstIndex(of: "/") {
            guard let n = Double(body[..<slash]), let d = Double(body[body.index(after: slash)...]), d > 0 else { return nil }
            return n / d
        }
        return Double(body)
    }

    static func parseRVR(_ t: String) -> RunwayVisualRange? {
        let parts = t.dropFirst().split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let rwy = String(parts[0])
        guard rwy.count >= 2, rwy.prefix(2).allSatisfy(\.isNumber) else { return nil }
        let digits = parts[1].drop(while: { $0 == "P" || $0 == "M" }).prefix(while: \.isNumber)
        guard let v = Int(digits) else { return nil }
        let feet = parts[1].hasSuffix("FT")
        return RunwayVisualRange(runway: rwy, metres: feet ? Int(Double(v) * 0.3048) : v)
    }

    static func parseCloud(_ t: String) -> CloudLayer? {
        guard t.count >= 6, let cover = CloudCover(rawValue: String(t.prefix(3))) else { return nil }
        let hPart = t.dropFirst(3).prefix(3)
        let base = Int(hPart).map { $0 * 100 }
        if base == nil && hPart != "///" { return nil }
        let suffix = String(t.dropFirst(6))
        let conv = (suffix == "CB" || suffix == "TCU") ? suffix : nil
        return CloudLayer(cover: cover, baseFeet: base, convective: conv)
    }

    static func parseTempDew(_ t: String) -> (Double?, Double?)? {
        guard !t.contains("SM"), let slash = t.firstIndex(of: "/") else { return nil }
        let parts = [t[..<slash], t[t.index(after: slash)...]]
        if parts[1].contains("/") && !parts[1].allSatisfy({ $0 == "/" }) { return nil }
        func value(_ s: Substring) -> Double?? {
            if s.isEmpty || s.allSatisfy({ $0 == "/" }) { return .some(nil) }
            let neg = s.hasPrefix("M")
            let digits = neg ? s.dropFirst() : s
            guard digits.count == 2, let v = Double(digits) else { return nil }
            return .some(neg ? -v : v)
        }
        guard let a = value(parts[0]), let b = value(parts[1]) else { return nil }
        if a == nil && b == nil && t.count < 3 { return nil }
        return (a, b)
    }

    static func isWeather(_ t: String) -> Bool {
        var s = Substring(t)
        if s.hasPrefix("+") || s.hasPrefix("-") { s = s.dropFirst() }
        if s.hasPrefix("VC") { s = s.dropFirst(2) }
        if s.hasPrefix("RE") { s = s.dropFirst(2) }
        if s.count >= 2, descriptors.contains(String(s.prefix(2))) {
            s = s.dropFirst(2)
            if s.isEmpty { return true } // e.g. "TS"
        }
        guard !s.isEmpty, s.count % 2 == 0 else { return false }
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard weatherCodes.contains(String(s[idx..<next])) else { return false }
            idx = next
        }
        return true
    }
}
