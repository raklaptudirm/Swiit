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
}
