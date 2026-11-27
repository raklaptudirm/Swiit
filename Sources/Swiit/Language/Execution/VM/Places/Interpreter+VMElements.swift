import Foundation

// The elements and members of lists, strings and dictionaries the loop reads and changes where they
// are.

extension Interpreter {
    /// What a member of a list or a string the loop makes itself gives, when the receiver and argument
    /// are plainly of the kinds it knows; nil, with nothing changed, otherwise. Each but a subscript
    /// makes the one step the tree evaluator's call of the member does.
    func fastMember(
        _ kind: FastMember,
        _ registers: UnsafeMutablePointer<Value>,
        _ receiver: Register,
        _ argument: Register
    ) throws -> Value? {
        if kind == .append {
            guard registers[Int(receiver)].isList(likeElement: registers[Int(argument)]) else {
                return nil
            }
            try checkInterrupt()
            _ = registers[Int(receiver)].appendLikeElements(registers[Int(argument)])
            return .nothing
        }
        guard
            let value = FastMember.read(kind, registers[Int(receiver)], registers[Int(argument)])
        else { return nil }
        if kind.takesStep { try checkInterrupt() }
        return value
    }
}

extension Value {
    /// Whether this is a list whose first element is of the kind `element` is.
    func isList(likeElement element: Value) -> Bool {
        guard case .list(let items) = storage, let first = items.first else { return false }
        switch (first.storage, element.storage) {
        case (.int, .int), (.double, .double), (.bool, .bool), (.string, .string): return true
        default: return false
        }
    }

    /// Appends `element` to this list when its first element is of the kind `element` is (a number,
    /// a Bool or a string, each its own), so that no conversion to the list's element type is in
    /// question. The list is changed where it is, not copied. False, and nothing changed, otherwise.
    mutating func appendLikeElements(_ element: Value) -> Bool {
        guard case .list(var items) = storage, let first = items.first else { return false }
        switch (first.storage, element.storage) {
        case (.int, .int), (.double, .double), (.bool, .bool), (.string, .string): break
        default: return false
        }
        storage = .nothing
        items.append(element)
        storage = .list(items)
        return true
    }
}

extension Value {
    /// Adds `suffix` to this string where it is, not to a copy of it. This must be a string.
    mutating func appendText(_ suffix: String) {
        guard case .string(var text) = storage else { return }
        storage = .nothing
        text += suffix
        storage = .string(text)
    }
}

extension Value {
    /// Sets the element of this list or dictionary at `key` to `value`, or to the result of `op` on what
    /// it holds (`fallback` if the dictionary has nothing there) and `value`, when the kinds fit: an
    /// index of a list within it, and numbers, Bools or strings of one kind. The collection is
    /// changed where it is, not copied. False, with nothing changed, otherwise.
    mutating func setElement(
        _ key: Value,
        _ fallback: Value?,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        // Nothing is bound while the collection is tested, so that it is changed where it is.
        if case .list = storage { return setListElement(key, fallback, op, value) }
        if case .dictionary = storage { return setDictionaryElement(key, fallback, op, value) }
        return false
    }

    private mutating func setListElement(
        _ key: Value,
        _ fallback: Value?,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        guard fallback == nil, case .int(let index) = key.storage,
            case .list(var items) = storage, items.indices.contains(index)
        else { return false }
        let new: Value
        if let op {
            guard let combined = Value.combined(items[index], op, value) else { return false }
            new = combined
        } else {
            new = value
        }
        storage = .nothing
        items[index] = new
        storage = .list(items)
        return true
    }

    private mutating func setDictionaryElement(
        _ key: Value,
        _ fallback: Value?,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        guard case .dictionary(var dictionary) = storage else { return false }
        let found = dictionary.index(forKey: key)
        let new: Value
        if let op {
            guard let current = found.map({ dictionary.values[$0] }) ?? fallback,
                current != .nothing, let combined = Value.combined(current, op, value)
            else { return false }
            new = combined
        } else {
            guard fallback == nil else { return false }
            new = value
        }
        // Nothing else holds the dictionary while it changes, so that it changes where it is. An entry
        // that is there is found once, by its index.
        storage = .nothing
        if let found {
            if new == .nothing {
                dictionary.remove(at: found)
            } else {
                dictionary.values[found] = new
            }
        } else if new != .nothing {
            dictionary[key] = new
        }
        storage = .dictionary(dictionary)
        return true
    }
}
