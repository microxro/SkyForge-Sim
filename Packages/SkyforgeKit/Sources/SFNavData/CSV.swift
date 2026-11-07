// SKYFORGE — Apache-2.0
// RFC 4180 CSV reader: quoted fields, escaped quotes, embedded commas and newlines, UTF-8.

public enum CSV {
    /// Parses CSV text into rows of fields.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = [UInt8]()
        var inQuotes = false
        let bytes = Array(text.utf8)
        var i = 0
        func endField() { row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true) }
        while i < bytes.count {
            let c = bytes[i]
            if inQuotes {
                if c == UInt8(ascii: "\"") {
                    if i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "\"") { field.append(c); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case UInt8(ascii: "\""): inQuotes = true
                case UInt8(ascii: ","): endField()
                case UInt8(ascii: "\r"): break
                case UInt8(ascii: "\n"):
                    endField(); rows.append(row); row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endField(); rows.append(row) }
        return rows
    }

    /// Parses with a header row into dictionaries keyed by column name.
    public static func records(_ text: String) -> [[String: String]] {
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { r in
            var d: [String: String] = [:]
            for (k, name) in header.enumerated() where k < r.count { d[name] = r[k] }
            return d
        }
    }
}
