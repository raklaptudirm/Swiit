import Foundation
import SwishKit

/// A pull-based stream of values between in-process pipeline stages. A
/// stage only runs when downstream asks for its next item, so
/// `… | first 5` stops upstream work early.
@_spi(Shell) public final class ValueStream {
    private let pull: () throws -> Value?

    @_spi(Shell) public init(_ pull: @escaping () throws -> Value?) {
        self.pull = pull
    }

    @_spi(Shell) public func next() throws -> Value? {
        try pull()
    }

    @_spi(Shell) public static var empty: ValueStream {
        ValueStream { nil }
    }

    /// A list flows as its elements, as does a Swift sequence (a Set, a
    /// range of Ints, a FilePath's components); nothing as no items,
    /// anything else as a single item.
    @_spi(Shell) public static func elements(of value: Value) -> ValueStream {
        if let flow = Interpreter.flow(of: value) { return ValueStream { try flow.read() } }
        let items: AnyIterator<Value>
        switch value {
        case .nothing:
            return .empty
        case .list:
            items = Interpreter.items(of: value)!
        case .object(let box as SwiftValue) where Bridge.types[box.typeName].map({
            !$0.genericParameters.isEmpty || $0.conformances["Sequence"] != nil
        }) == true:
            items = Interpreter.items(of: value) ?? AnyIterator([value].makeIterator())
        default:
            items = AnyIterator([value].makeIterator())
        }
        return ValueStream { items.next() }
    }
}
