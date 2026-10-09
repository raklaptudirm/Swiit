import SwishKit

extension Sequence where Element: Hashable {
    /// The items without repeats, first ones kept.
    public func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

extension Sequence {
    /// The value of one field of each item.
    /// - Parameter key: a field, as in get name or get(\.name)
    public func get<V>(_ key: KeyPath<Element, V>) -> [V] {
        map { $0[keyPath: key] }
    }

    /// The items in order of a field; Swift's sorted() and sorted(by:)
    /// sort by the items themselves or a closure.
    /// - Parameter by: the field, as in --by size or by: \.size
    public func sorted<V: Comparable>(@Flag by key: KeyPath<Element, V>) -> [Element] {
        // Ties keep their order.
        enumerated().map { (key: $1[keyPath: key], index: $0, item: $1) }
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.index < $1.index }.map(\.item)
    }
}
