import Foundation

/// A type that stands for text where a String is wanted: a command's output,
/// which is its text. It compares with strings and is accepted for a String
/// parameter, as `$(echo hi)` is for `"hi"`.
public protocol StandsForText {
    var text: String { get }
}
