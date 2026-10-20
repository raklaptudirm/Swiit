import Foundation

extension Value {
    /// The text it is, or stands for: a String, or what stands for one.
    var text: String? {
        switch self {
        case .string(let text): text
        case .object(let box as SwiftValue): (box.value as? any StandsForText)?.text
        default: nil
        }
    }
}

/// A type that stands for text where a String is wanted: a host type's text,
/// which is its text. It compares with strings and is accepted for a String
/// parameter, as `$(echo hi)` is for `"hi"`.
public protocol StandsForText {
    var text: String { get }
}
