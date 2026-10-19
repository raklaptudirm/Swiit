import Foundation

extension Value {
    /// The text it is, or stands for: a String, or what stands for one.
    @_spi(Layer) public var text: String? {
        switch self {
        case .string(let text): text
        case .object(let box as SwiftValue): (box.value as? any StandsForText)?.text
        default: nil
        }
    }
}
