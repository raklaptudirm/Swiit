import Foundation

extension Value {
    /// Text with styles, held as the Swift value it is.
    static func attributed(_ text: AttributedString) -> Value {
        SwiftValue.make(text, as: "AttributedString")
    }
}
