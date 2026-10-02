import Foundation

// Tolerant decoding helpers. The core is the source of truth and may add
// fields or send values this build does not know; a client must never fail a
// whole screen because one field has an unexpected shape.

/// ISO-8601 dates as the core writes them (`2026-10-01T12:00:00Z`), with or
/// without fractional seconds (Swift-written jobs.json, JS `toISOString`).
public enum CoreDate {
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    public static func parse(_ s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return plain.date(from: s) ?? fractional.date(from: s)
    }

    public static func format(_ d: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return plain.string(from: d)
    }
}

/// Decodes an element, or nil when it does not fit (used for lossy arrays).
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// The value, or nil when absent, null or of the wrong type.
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// An array that skips elements of the wrong shape; [] when absent or not an array.
    func lossyArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }

    func lossyDate(_ key: Key) -> Date? {
        lossy(String.self, key).flatMap(CoreDate.parse)
    }

    /// Numbers may arrive as Int or Double.
    func lossyDouble(_ key: Key) -> Double? {
        if let d = lossy(Double.self, key) { return d }
        return lossy(Int.self, key).map(Double.init)
    }

    func lossyInt(_ key: Key) -> Int? {
        if let i = lossy(Int.self, key) { return i }
        return lossy(Double.self, key).map { Int($0) }
    }
}

extension JSONDecoder {
    /// Decoder for core responses. Dates are handled field by field (see `CoreDate`).
    public static var core: JSONDecoder { JSONDecoder() }
}

extension JSONEncoder {
    public static var core: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
