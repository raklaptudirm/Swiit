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

    /// The names a `for` binds for each element: the one variable of a name, or the slots of a pattern
    /// and the site it is matched by.
    struct LoopVariables {
        var entering: [String: (slot: Register, mutable: Bool)] = [:]
        var variable: Register?
        var matched: (site: UInt32, names: [String])?
    }

    /// What the pattern of `loop` binds, and where.
    private mutating func loopVariables(of loop: ForLoop) throws -> LoopVariables {
        var found = LoopVariables()
        switch loop.pattern {
        case .wildcard:
            break
        case .binding(let name, let mutable):
            guard let local = loop.body.locals?.first(where: { $0.name == name }) else {
                throw Unsupported("a for variable without a slot")
            }
            found.variable = Register(local.slot)
            found.entering[name] = (Register(local.slot), mutable)
        default:
            let names = FrameResolver.names(in: loop.pattern)
            found.matched = (try site(loop.pattern, names: names, in: loop.body.locals), names)
            for bound in try slots(of: names, in: loop.body.locals) {
                found.entering[bound.name] = (bound.register, false)
            }
        }
        return found
    }

    /// `for x in xs`: of a collection, a string, a dictionary, or what has an iterator. A pattern that
    /// is not a name (`(i, x)`) is matched to each element as the runtime matches one.
    mutating func elementsLoop(_ loop: ForLoop, _ statement: Statement) throws {
        let bound = try loopVariables(of: loop)
        let (entering, variable, matched) = (bound.entering, bound.variable, bound.matched)
        finished(statement)

        let mark = nextTemporary
        // The state of the iteration, the element, and the position in a list (`iterate`).
        let iterator = try allocate()
        let element = try allocate()
        _ = try allocate()
        // `(k, v)`: the fields of a tuple go where the names are, and the general match is for what is
        // not one.
        var pieces: DestructureSite?
        if matched != nil, case .tuple(let patterns) = loop.pattern,
            let places = try places(of: patterns, in: loop.body.locals)
        {
            pieces = DestructureSite(arity: patterns.count, targets: places)
        }
        // A pair of names over a dictionary reads its keys and values from two lists.
        let pairs = pieces?.arity == 2 && !loop.isAwait
        if pairs { _ = try allocate() }
        let sequence = try operand(loop.sequence)
        if pairs {
            emit(.iteration(.iteratePairs(dst: iterator, sequence: sequence)))
        } else {
            emit(.iteration(.iterate(dst: iterator, sequence: sequence, awaiting: loop.isAwait)))
        }
        let head = here
        let next: Int
        if let pieces, pairs {
            code.destructures.append(pieces)
            next = emit(
                .iteration(
                    .iterateNextPair(
                        iterator: iterator,
                        variable: element,
                        site: UInt32(code.destructures.count - 1),
                        exit: 0,
                        skip: 2
                    )
                )
            )
        } else {
            next = emit(
                .iterateNext(
                    iterator: iterator,
                    variable: matched != nil ? element : (variable ?? element),
                    exit: 0
                )
            )
        }
        var mismatch: Int?
        if let matched {
            var destructure: Int?
            if let pieces {
                if !pairs { code.destructures.append(pieces) }
                destructure = emit(
                    .patterns(
                        .destructure(
                            site: UInt32(code.destructures.count - 1),
                            value: element,
                            offset: 0
                        )
                    )
                )
            }
            mismatch = emit(.patterns(.match(pattern: matched.site, value: element, fail: 0)))
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
            emit(.iteration(.iterationMismatch(element: element)))
        }
        patch(next, to: here)
        for index in context.breaks { patch(index, to: here) }
        nextTemporary = mark
    }
}
