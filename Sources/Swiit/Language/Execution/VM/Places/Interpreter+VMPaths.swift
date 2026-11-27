import Foundation

// Changing a part of a local in its register, as the tree evaluator does a place in a variable: the
// value is moved out while the change is made, so that a collection in it is not copied.

extension Interpreter {
    /// `site`'s place in the register `local` (counted from the stack's start) set to what is in
    /// `value`, or changed by its operator. False, with nothing changed, when the place is not one
    /// that is changed where it is: the tree evaluator's `plainPlace` says.
    func assignPath(
        _ site: PathSite,
        local: Int,
        keys: Int,
        value: Int,
        on stack: VMStack
    ) throws -> Bool {
        if site.isIndexOnly {
            var root = stack.base[local]
            stack.base[local] = .nothing
            let done = setElement(
                &root,
                keys: stack.base + keys,
                count: site.steps.count,
                op: site.op,
                value: stack.base[value]
            )
            stack.base[local] = root
            if done { return true }
        }
        var next = 0
        let found = try plainPlace(in: stack.base[local], site.steps, op: site.op) { _ in
            defer { next += 1 }
            return stack.base[keys + next]
        }
        guard let place = found else { return false }
        var stored = stack.base[value]
        if site.op == nil, let validate = place.validate { stored = try validate(stored) }
        // Moved out of its register while it changes; the stack may move meanwhile, so it is put
        // back by index.
        var held = stack.base[local]
        stack.base[local] = .nothing
        defer { stack.base[local] = held }
        try descend(&held, place.steps[...], store(stored, at: place, op: site.op))
        return true
    }

    /// The element of lists in lists that the `count` keys from `keys` name, set to
    /// `value` or changed by `op`, where it is: moved out while it changes, so that no list is copied
    /// that nothing else holds. False, with every value put back, where it is not that: a level that
    /// is not a list, a key that is not an Int in range, a leaf with an operator of its own, or an
    /// operation that fails, which the long way then fails as it does.
    private func setElement(
        _ list: inout Value,
        keys: UnsafeMutablePointer<Value>,
        count: Int,
        op: BinaryOperator?,
        value: Value
    ) -> Bool {
        guard case .int(let position) = keys[0].storage, case .list(var items) = list.storage,
            items.indices.contains(position)
        else { return false }
        // Only `items` holds the list from here, so that it is changed where it is.
        list = .nothing
        var done = false
        var element = items[position]
        items[position] = .nothing
        if count == 1 {
            if let op {
                switch element.storage {
                case .int, .double, .string, .list, .bool:
                    if (try? applyInPlace(op, &element, value)) != nil { done = true }
                default: break
                }
            } else {
                element = value
                done = true
            }
        } else {
            done = setElement(
                &element,
                keys: keys + 1,
                count: count - 1,
                op: op,
                value: value
            )
        }
        items[position] = element
        list = .list(items)
        return done
    }
}
