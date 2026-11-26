import Foundation

extension CodeCompiler {
    /// Where each name of a tuple pattern of names and wildcards goes, with the position it takes; nil
    /// for any other pattern.
    private func places(
        of patterns: [Pattern],
        in locals: [Program.Local]?
    ) throws -> [(position: Int, register: Register)]? {
        var places: [(position: Int, register: Register)] = []
        for (position, pattern) in patterns.enumerated() {
            switch pattern {
            case .wildcard: continue
            case .binding(let name, _):
                guard let local = locals?.first(where: { $0.name == name }) else { return nil }
                places.append((position, Register(local.slot)))
            default: return nil
            }
        }
        return places
    }

    /// `for x in xs`: of a collection, a string, a dictionary, or what has an iterator. A pattern that
    /// is not a name (`(i, x)`) is matched to each element as the runtime matches one.
    mutating func elementsLoop(_ loop: ForLoop, _ statement: Statement) throws {
        var entering: [String: (slot: Register, mutable: Bool)] = [:]
        var variable: Register?
        var matched: (site: UInt32, names: [String])?
        switch loop.pattern {
        case .wildcard: break
        case .binding(let name, let mutable):
            guard let local = loop.body.locals?.first(where: { $0.name == name }) else {
                throw Unsupported("a for variable without a slot")
            }
            variable = Register(local.slot)
            entering[name] = (Register(local.slot), mutable)
        default:
            let names = FrameResolver.names(in: loop.pattern)
            matched = (try site(loop.pattern, names: names, in: loop.body.locals), names)
            for bound in try slots(of: names, in: loop.body.locals) {
                entering[bound.name] = (bound.register, false)
            }
        }
        finished(statement)
        let mark = nextTemporary
        // The state of the iteration, the element, and the position in a list (`iterate`).
        let iterator = try allocate()
        let element = try allocate()
        _ = try allocate()
        let sequence = try operand(loop.sequence)
        emit(.iterate(dst: iterator, sequence: sequence, awaiting: loop.isAwait))
        let head = here
        let next = emit(
            .iterateNext(
                iterator: iterator,
                variable: matched != nil ? element : (variable ?? element),
                exit: 0
            )
        )
        var mismatch: Int?
        if let matched {
            // `(k, v)`: the fields of a tuple go where the names are, and the general match is for what is
            // not one.
            var destructure: Int?
            if case .tuple(let patterns) = loop.pattern,
                let places = try places(of: patterns, in: loop.body.locals)
            {
                code.destructures.append(DestructureSite(arity: patterns.count, targets: places))
                destructure = emit(
                    .destructure(
                        site: UInt32(code.destructures.count - 1),
                        value: element,
                        offset: 0
                    )
                )
            }
            mismatch = emit(.match(pattern: matched.site, value: element, fail: 0))
            if let destructure { patch(destructure, to: here) }
            for name in matched.names {
                if let bound = entering[name] { bindBox(bound.slot) }
            }
        } else if let variable {
            bindBox(variable)
        }
        breakables.append(
            Breakable(
                label: loop.label,
                isSwitch: false,
                scopeDepth: scopes.count,
                continueTarget: head
            )
        )
        emit(.tick)
        try block(loop.body, entering: entering)
        jump(to: head)
        let context = breakables.removeLast()
        if let mismatch {
            patch(mismatch, to: here)
            emit(.iterationMismatch(element: element))
        }
        patch(next, to: here)
        for index in context.breaks { patch(index, to: here) }
        nextTemporary = mark
    }
}
