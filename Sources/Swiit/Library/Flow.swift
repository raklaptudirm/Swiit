import SwishKit

/// Items read one at a time, as a pipeline's stages pass them, so a stage
/// only does the work the one after it asks for: `yes | map { … } | prefix 3`
/// ends. Not a `Sequence`, because reading an item can throw, as a closure
/// can, and an iterator's `next()` can't.
public struct Flow<Element> {
    /// Reads the next item, or gives nil when there are no more. A property
    /// rather than a method, so it isn't a stage of its own.
    public let read: () throws -> Element?

    public init(_ read: @escaping () throws -> Element?) {
        self.read = read
    }

    /// The items of any sequence.
    public init<Items: Sequence>(_ items: Items) where Items.Element == Element {
        var iterator = items.makeIterator()
        self.init { iterator.next() }
    }

    /// The items for which the predicate returns true.
    /// - Parameter isIncluded: a closure like { $0.size > 1.mb }
    public func filter(_ isIncluded: @escaping (Element) throws -> Bool) -> Flow<Element> {
        Flow {
            while let item = try read() {
                if try isIncluded(item) { return item }
            }
            return nil
        }
    }

    /// Each item transformed, nil results included, as Swift's map.
    /// - Parameter transform: a closure like { $0.name }, or a key path like \.name
    public func map<T>(_ transform: @escaping (Element) throws -> T) -> Flow<T> {
        Flow<T> { try read().map(transform) }
    }

    /// Each item transformed, nil results dropped.
    /// - Parameter transform: a closure like { $0.name }, or a key path like \.name
    public func compactMap<T>(_ transform: @escaping (Element) throws -> T?) -> Flow<T> {
        Flow<T> {
            while let item = try read() {
                if let result = try transform(item) { return result }
            }
            return nil
        }
    }

    /// The first items; stops reading after them.
    public func prefix(_ maxLength: Int = 1) -> Flow<Element> {
        var taken = 0
        return Flow {
            guard taken < maxLength, let item = try read() else { return nil }
            taken += 1
            return item
        }
    }
}
