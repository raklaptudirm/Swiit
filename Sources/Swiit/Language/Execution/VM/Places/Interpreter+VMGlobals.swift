import Foundation

// Reading and changing global variables through the cells the loop keeps for them.

extension Interpreter {
    /// Finds the cell of the variable `site` names, from the scopes `function` runs in, and keeps it
    /// until a name changes. Nothing is kept for a variable that is worked out when read, or for a
    /// body that has a scope of its own.
    func findGlobal(_ site: GlobalSite, _ function: Function, _ code: Code) {
        site.version = scopeVersion
        site.function = ObjectIdentifier(function)
        site.cell = nil
        guard code.isPlain, let binding = lookup(site.name), !binding.isComputed else { return }
        site.cell = binding.cell
        site.isMutable = binding.mutable && binding.special == nil
    }

    /// `cell = value` or `cell op= value` when both are plainly numbers of one kind: false when the
    /// assignment is for the general one to make (another kind, an operator a type defines, a check
    /// of the value against the variable's type).
    @inline(__always)
    func setNumber(in cell: Binding.Cell, _ op: BinaryOperator?, to value: Value) -> Bool {
        // A string is added to where it is, taken out of the cell while it is.
        if op == .add, case .string(let suffix) = value.storage, case .string = cell.value.storage {
            var held = cell.value
            cell.value = .nothing
            held.appendText(suffix)
            cell.value = held
            return true
        }
        switch (cell.value.storage, value.storage) {
        case (.int(let current), .int(let new)):
            switch op {
            case nil: cell.value = .int(new)
            case .add?:
                let (sum, overflow) = current.addingReportingOverflow(new)
                guard !overflow else { return false }
                cell.value = .int(sum)
            case .subtract?:
                let (difference, overflow) = current.subtractingReportingOverflow(new)
                guard !overflow else { return false }
                cell.value = .int(difference)
            case .multiply?:
                let (product, overflow) = current.multipliedReportingOverflow(by: new)
                guard !overflow else { return false }
                cell.value = .int(product)
            default: return false
            }
            return true
        case (.double(let current), .double(let new)):
            switch op {
            case nil: cell.value = .double(new)
            case .add?: cell.value = .double(current + new)
            case .subtract?: cell.value = .double(current - new)
            case .multiply?: cell.value = .double(current * new)
            default: return false
            }
            return true
        case (.string, .string):
            guard op == nil else { return false }
            cell.value = value
            return true
        default: return false
        }
    }
}

extension Interpreter {
    /// The value of the global `site` names, read from its cell when it has one, and by the tree
    /// evaluator's lookup where it has not (a variable that is not there, or is worked out, or weak).
    @inline(__always)
    func globalValue(_ site: GlobalSite, _ function: Function, _ code: Code) throws -> Value {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        if let cell = site.cell {
            let value = cell.value
            if case .object(is WeakReference) = value.storage {
                return try evaluate(.variable(site.name))
            }
            return value
        }
        return try evaluate(.variable(site.name))
    }

    /// `name = value` or `name op= value` of a global: set in its cell when both are numbers of one
    /// kind, and by the tree evaluator's assignment where not.
    @inline(__always)
    func assignGlobal(
        _ site: GlobalSite,
        _ assignment: Assignment,
        _ value: Value,
        _ function: Function,
        _ code: Code
    ) throws {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        if site.isMutable, let cell = site.cell, setNumber(in: cell, assignment.op, to: value) {
            return
        }
        var long = assignment
        long.value = .literal(value)
        try assign(long)
    }
}

extension Interpreter {
    /// A list's or a string's member (`append`, `count`, a subscript) of a global, where the global's
    /// cell holds the value: read there, or, for `append`, changed there. Nil, with nothing changed, where
    /// the kinds do not fit, which the tree evaluator then does.
    func fastGlobalMember(
        _ kind: FastMember,
        _ site: GlobalSite,
        _ function: Function,
        _ code: Code,
        _ argument: Value
    ) throws -> Value? {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        guard let cell = site.cell else { return nil }
        switch kind {
        case .append:
            guard site.isMutable, cell.value.isList(likeElement: argument) else { return nil }
            try checkInterrupt()
            // Taken out of the cell, so that it is changed where it is and not copied.
            var held = cell.value
            cell.value = .nothing
            _ = held.appendLikeElements(argument)
            cell.value = held
            return .nothing
        default:
            guard let value = FastMember.read(kind, cell.value, argument) else { return nil }
            if kind.takesStep { try checkInterrupt() }
            return value
        }
    }

    /// `name.field = value` or `name.field op= value` of a global holding a struct or an instance, set
    /// in the cell as `setMember` sets a local's. False, with nothing changed, otherwise.
    func setGlobalMember(
        _ site: GlobalSite,
        _ member: MemberSite,
        _ function: Function,
        _ code: Code,
        _ assignment: (op: BinaryOperator?, value: Value)
    ) throws -> Bool {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        guard site.isMutable, let cell = site.cell else { return false }
        return setMember(member, in: cell, assignment.op, assignment.value)
    }
}
