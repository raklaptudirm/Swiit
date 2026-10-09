import Foundation

extension Date {
    /// A date written as ISO 8601 text, like `2026-09-27T14:03:00Z`; nil for anything else.
    public init?(_ text: String) {
        guard let date = try? Date(text, strategy: .iso8601) else { return nil }
        self = date
    }
}

extension Date {
    /// How many seconds apart two dates are: `later - earlier`.
    public static func - (lhs: Date, rhs: Date) -> TimeInterval {
        lhs.timeIntervalSince(rhs)
    }

    /// A date some whole seconds later or earlier, as `date + 60`.
    public static func + (lhs: Date, rhs: Int) -> Date {
        lhs.addingTimeInterval(TimeInterval(rhs))
    }

    public static func - (lhs: Date, rhs: Int) -> Date {
        lhs.addingTimeInterval(-TimeInterval(rhs))
    }
}
