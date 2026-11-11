import Foundation

// A date, held as the Swift value it is.

extension Value {
    /// A date, held as the Swift value it is.
    static func date(_ date: Date) -> Value {
        SwiftValue.make(date, as: "Date")
    }

    /// The date it holds, if it's one.
    var date: Date? {
        if case .object(let box as SwiftValue) = self.storage { box.value as? Date } else { nil }
    }
}
