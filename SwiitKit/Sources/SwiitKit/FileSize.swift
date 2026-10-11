import Foundation

/// An amount of bytes, shown in decimal units as Finder shows them (`532 B`,
/// `1.2 KB`, `123 MB`) and written `1.5mb` in Swish. It adds and subtracts,
/// scales by a number, and divides by another size for a ratio. Encodes as
/// its byte count.
public struct FileSize: Codable, Hashable, Comparable, Sendable, LosslessStringConvertible {
    /// How many bytes.
    public var bytes: Int

    public init(bytes: Int) {
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        bytes = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }

    // MARK: Units

    /// The units a size is written in: decimal (`kb`) and binary (`kib`).
    public static let units: [String: Int] = [
        "b": 1, "kb": 1_000, "mb": 1_000_000, "gb": 1_000_000_000, "tb": 1_000_000_000_000,
        "kib": 1 << 10, "mib": 1 << 20, "gib": 1 << 30, "tib": 1 << 40,
    ]

    /// `1.5` of a unit (`mb`), or nil if there's no such unit or the size is too large.
    public init?(_ amount: Double, unit: String) {
        guard let multiplier = FileSize.units[unit.lowercased()] else { return nil }
        let bytes = (amount * Double(multiplier)).rounded()
        guard bytes.magnitude < Double(Int.max) else { return nil }
        self.init(bytes: Int(bytes))
    }

    /// `1024`, `1.5mb`, `1.5 MB`, `2kib`; nil for anything else.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let amount = Double(number) else { return nil }
        self.init(amount, unit: unit.isEmpty ? "b" : unit)
    }

    // MARK: Showing

    public var description: String {
        let names = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = Double(bytes.magnitude)
        var unit = 0
        while size >= 1000 && unit < names.count - 1 {
            size /= 1000
            unit += 1
        }
        let sign = bytes < 0 ? "-" : ""
        if unit == 0 { return "\(sign)\(bytes.magnitude) B" }
        let number = size < 100 ? String(format: "%.1f", size) : String(format: "%.0f", size)
        return "\(sign)\(number) \(names[unit])"
    }

    // MARK: Arithmetic

    public static func < (lhs: FileSize, rhs: FileSize) -> Bool { lhs.bytes < rhs.bytes }

    /// A size from a number of bytes worked out in floating point; an error
    /// where it wouldn't fit.
    private static func scaled(_ bytes: Double) throws -> FileSize {
        guard bytes.magnitude < Double(Int.max) else { throw SwiitError("arithmetic overflow") }
        return FileSize(bytes: Int(bytes))
    }

    private static func divided(_ bytes: Int, by divisor: Double) throws -> FileSize {
        guard divisor != 0 else { throw SwiitError("division by zero") }
        return try scaled(Double(bytes) / divisor)
    }

    public static func + (lhs: FileSize, rhs: FileSize) throws -> FileSize { try scaled(Double(lhs.bytes) + Double(rhs.bytes)) }
    public static func - (lhs: FileSize, rhs: FileSize) throws -> FileSize { try scaled(Double(lhs.bytes) - Double(rhs.bytes)) }
    public static prefix func - (operand: FileSize) -> FileSize { FileSize(bytes: -operand.bytes) }

    public static func * (lhs: FileSize, rhs: Int) throws -> FileSize { try scaled(Double(lhs.bytes) * Double(rhs)) }
    public static func * (lhs: FileSize, rhs: Double) throws -> FileSize { try scaled(Double(lhs.bytes) * rhs) }
    public static func * (lhs: Int, rhs: FileSize) throws -> FileSize { try rhs * lhs }
    public static func * (lhs: Double, rhs: FileSize) throws -> FileSize { try rhs * lhs }

    public static func / (lhs: FileSize, rhs: Int) throws -> FileSize { try divided(lhs.bytes, by: Double(rhs)) }
    public static func / (lhs: FileSize, rhs: Double) throws -> FileSize { try divided(lhs.bytes, by: rhs) }
    /// How many of one fit in the other.
    public static func / (lhs: FileSize, rhs: FileSize) -> Double { Double(lhs.bytes) / Double(rhs.bytes) }
}

extension FileSize: SwiitDisplayed {
    public var swiitDescription: String { description }
    /// A number: in the constant color, and a column of them lines up on the right.
    public var swiitShape: DisplayShape { DisplayShape(role: .constant, isNumeric: true) }
}
