import Foundation
import SwiitKit

public struct Binding {
    enum Special {
        /// `self` in a struct's `init`, which may set its `let` properties.
        case initializing
    }

    /// Where the value lives, shared by every scope that has this
    /// variable: the one it was declared in, and closures that use it.
    public let cell: Cell
    public var value: Value {
        get { cell.value }
        nonmutating set { cell.value = newValue }
    }
    public let mutable: Bool
    /// Its value is worked out on each read; looking at its type reads nothing.
    var isComputed: Bool { cell.isComputed }
    /// Declared with `func`, which makes it callable in command mode.
    public var isFunction = false
    var special: Special?

    public init(value: Value, mutable: Bool, isFunction: Bool = false) {
        self.init(value: value, mutable: mutable, isFunction: isFunction, special: nil)
    }

    init(value: Value, mutable: Bool, isFunction: Bool = false, special: Special?) {
        cell = Cell(value)
        self.mutable = mutable
        self.isFunction = isFunction
        self.special = special
    }

    /// A name whose value is worked out each time it is read, like the shell's
    /// `jobs`, and can't be assigned.
    public init(computed value: @escaping () -> Value) {
        cell = Cell(compute: value)
        mutable = false
    }

    /// A variable's storage, so a closure can share it without keeping the
    /// whole scope it's in.
    public final class Cell {
        private var stored: Value
        private let compute: (() -> Value)?

        public var value: Value {
            get { compute?() ?? stored }
            set { stored = newValue }
        }

        public init(_ value: Value) {
            stored = value
            compute = nil
        }

        /// Worked out on each read, not stored.
        var isComputed: Bool { compute != nil }

        public init(compute: @escaping () -> Value) {
            stored = .nothing
            self.compute = compute
        }
    }
}

/// A reference type so closures share variables with the scope they
/// captured, as in Swift.
public final class Scope {
    public var bindings: BindingTable
    /// For a closure's scope: where it was made, held weakly so it can't
    /// keep them alive, for names bound there after it was made (a local
    /// function declared further down).
    var fallbacks: [WeakScope] = []

    public init(_ bindings: [String: Binding] = [:]) {
        self.bindings = BindingTable(bindings)
    }

    init(table: BindingTable) {
        bindings = table
    }

    /// Declares a function by its name: another of that name is overloaded,
    /// unless the signature is the same, which replaces it.
    public func declare(_ function: Function, named name: String) {
        var candidates = [function]
        if let existing = bindings[name], existing.isFunction,
           case .function(let callable) = existing.value, let set = callable as? OverloadSet {
            // The same signature is replaced where it stood, so each overload keeps its place (the checker numbers them).
            if let position = set.candidates.firstIndex(where: { $0.hasSameSignature(as: function) }) {
                candidates = set.candidates
                candidates[position] = function
                candidates = candidates.enumerated().filter { $0.offset == position || !$0.element.hasSameSignature(as: function) }.map(\.element)
            } else {
                candidates = set.candidates + candidates
            }
        }
        bindings[name] = Binding(value: .function(OverloadSet(name: name, candidates: candidates)), mutable: false, isFunction: true)
    }

    /// What `name` is bound to here, or where this scope was made.
    func binding(named name: String) -> Binding? {
        if let found = bindings[name] { return found }
        if fallbacks.isEmpty { return nil }
        for fallback in fallbacks.reversed() {
            if let found = fallback.scope?.bindings[name] { return found }
        }
        return nil
    }

    /// The scope binding `name`: this one, or where it was made.
    public func holding(_ name: String) -> Scope? {
        if bindings[name] != nil { return self }
        for fallback in fallbacks.reversed() {
            if let scope = fallback.scope, scope.bindings[name] != nil { return scope }
        }
        return nil
    }
}

struct WeakScope {
    weak var scope: Scope?
}


/// What a scope binds: names to bindings. A scope is nearly always a few names (a call's arguments and locals), for
/// which hashing every name on every read costs more than comparing a handful of short strings, so those are kept in an
/// array and searched; a scope that grows past `limit` (the global one) gets a dictionary of positions as well.
public struct BindingTable: Sequence, ExpressibleByDictionaryLiteral {
    private struct Entry {
        let name: String
        var binding: Binding
    }

    private static let limit = 12
    private var entries: [Entry] = []
    private var positions: [String: Int]?

    public init() {}

    public init(dictionaryLiteral elements: (String, Binding)...) {
        for (name, binding) in elements { self[name] = binding }
    }

    public init(_ dictionary: [String: Binding]) {
        entries.reserveCapacity(dictionary.count)
        for (name, binding) in dictionary { self[name] = binding }
    }

    /// An empty table with room for `capacity` names.
    init(capacity: Int) {
        entries.reserveCapacity(capacity)
    }

    private func position(of name: String) -> Int? {
        if let positions { return positions[name] }
        for index in entries.indices where entries[index].name == name { return index }
        return nil
    }

    public subscript(name: String) -> Binding? {
        get { position(of: name).map { entries[$0].binding } }
        set {
            if let index = position(of: name) {
                if let newValue { entries[index].binding = newValue } else { remove(at: index) }
            } else if let newValue {
                entries.append(Entry(name: name, binding: newValue))
                if positions != nil {
                    positions![name] = entries.count - 1
                } else if entries.count > BindingTable.limit {
                    positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.name, $0) })
                }
            }
        }
    }

    private mutating func remove(at index: Int) {
        entries.remove(at: index)
        if positions != nil { positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.name, $0) }) }
    }

    @discardableResult
    public mutating func removeValue(forKey name: String) -> Binding? {
        guard let index = position(of: name) else { return nil }
        let removed = entries[index].binding
        remove(at: index)
        return removed
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var keys: [String] { entries.map(\.name) }
    public var values: [Binding] { entries.map(\.binding) }

    public func makeIterator() -> some IteratorProtocol<(key: String, value: Binding)> {
        entries.lazy.map { (key: $0.name, value: $0.binding) }.makeIterator()
    }

    /// The names of both, the later table's binding for a name in both.
    public func merging(_ other: BindingTable, uniquingKeysWith combine: (Binding, Binding) -> Binding) -> [String: Binding] {
        var merged = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.binding) })
        for entry in other.entries {
            merged[entry.name] = merged[entry.name].map { combine($0, entry.binding) } ?? entry.binding
        }
        return merged
    }
}
