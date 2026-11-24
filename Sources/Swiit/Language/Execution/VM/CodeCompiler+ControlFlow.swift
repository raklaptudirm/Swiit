import Foundation

/// What a `switch`'s cases and a `do`'s clauses share, and where they differ.
struct CaseDispatch {
    /// The register of the value the cases are matched against.
    let subject: Register
    /// A clause with no pattern binds the subject under this name (a bare `catch` binds `error`).
    var anyName: String?
    /// Whether these are a `switch`'s, where `fallthrough` goes on to the next body.
    let isSwitch: Bool
    /// What the body of the case that was taken begins with.
    var whenTaken: Instruction?
    /// What runs when no case matches.
    let noMatch: Instruction
}

extension CodeCompiler {
    // MARK: Patterns

    /// Where each name a pattern binds goes: the slots of the block that follows it.
    private func slots(
        of names: [String],
        in locals: [Program.Local]?
    ) throws -> [(
        name: String, register: Register
    )] {
        try names.map { name in
            guard let local = locals?.first(where: { $0.name == name }) else {
                throw Unsupported("a pattern's name without a slot")
            }
            return (name, Register(local.slot))
        }
    }

    /// A pattern the runtime matches: what it compares with must not name a local, which the
    /// runtime would look for by name in a frame the VM does not keep.
    private func isPlain(_ pattern: Pattern) -> Bool {
        switch pattern {
        case .wildcard, .binding, .isType: true
        case .expression(let value): isConstant(value)
        case .enumCase(_, _, let arguments): (arguments ?? []).allSatisfy { isPlain($0.pattern) }
        case .cast(let inner, _), .some(let inner): isPlain(inner)
        case .tuple(let patterns): patterns.allSatisfy(isPlain)
        case .partialRange(let lower, let upper, _):
            [lower, upper].allSatisfy { $0.map(isConstant) ?? true }
        }
    }

    private mutating func site(
        _ pattern: Pattern,
        names: [String],
        in locals: [Program.Local]?
    ) throws -> UInt32 {
        guard isPlain(pattern) else { throw Unsupported("a pattern that compares with a local") }
        let bound = try slots(of: names, in: locals)
        code.patterns.append(PatternSite(pattern: pattern, slots: bound))
        return UInt32(code.patterns.count - 1)
    }

    // MARK: if and guard

    mutating func ifStatement(_ node: IfStatement, _ statement: Statement) throws {
        finished(statement)
        let mark = nextTemporary
        var entering: [String: (slot: Register, mutable: Bool)] = [:]
        let skip: Int
        switch node.condition {
        case .expression(let condition):
            let test = try operand(condition)
            skip = emit(.jumpIfFalse(condition: test, offset: 0))
        case .binding(let name, let mutable, let value):
            let held = try allocate()
            try expression(value, into: held)
            skip = emit(.jumpIfNil(register: held, offset: 0))
            let bound = try slots(of: [name], in: node.then.locals)[0].register
            emit(.move(dst: bound, src: held))
            bindBox(bound)
            entering[name] = (bound, mutable)
        case .pattern(let pattern, let value):
            let held = try allocate()
            try expression(value, into: held)
            let names = FrameResolver.names(in: pattern)
            skip = emit(
                .match(
                    pattern: try site(pattern, names: names, in: node.then.locals),
                    value: held,
                    fail: 0
                )
            )
            for bound in try slots(of: names, in: node.then.locals) {
                bindBox(bound.register)
                entering[bound.name] = (bound.register, false)
            }
        }
        nextTemporary = mark
        try block(node.then, entering: entering)
        if let otherwise = node.otherwise {
            let over = emit(.jump(offset: 0))
            patch(skip, to: here)
            try block(otherwise)
            patch(over, to: here)
        } else {
            patch(skip, to: here)
        }
    }

    /// `guard`: what the condition binds is in the slots the block it is in gave it, from the next
    /// statement on. When it fails the `else` runs, and must leave.
    mutating func guardStatement(
        _ condition: IfStatement.Condition,
        _ otherwise: Program,
        _ introduced: [Program.Local],
        range: Int32
    ) throws {
        let mark = nextTemporary
        let fail: Int
        var bound: [String: Local] = [:]
        switch condition {
        case .expression(let test):
            fail = emit(.jumpIfFalse(condition: try operand(test), offset: 0))
        case .binding(let name, let mutable, let value):
            let held = try allocate()
            try expression(value, into: held)
            fail = emit(.jumpIfNil(register: held, offset: 0))
            let slot = try slots(of: [name], in: introduced)[0].register
            emit(.move(dst: slot, src: held))
            bindBox(slot)
            bound[name] = local(slot, mutable: mutable)
        case .pattern(let pattern, let value):
            let held = try allocate()
            try expression(value, into: held)
            let names = FrameResolver.names(in: pattern)
            fail = emit(
                .match(
                    pattern: try site(pattern, names: names, in: introduced),
                    value: held,
                    fail: 0
                )
            )
            for slot in try slots(of: names, in: introduced) {
                bindBox(slot.register)
                bound[slot.name] = local(slot.register, mutable: false)
            }
        }
        nextTemporary = mark
        let over = emit(.jump(offset: 0))
        patch(fail, to: here)
        try block(otherwise)
        emit(.at(range: range))
        emit(.guardCarriedOn)
        patch(over, to: here)
        for (name, local) in bound { scopes[scopes.count - 1].locals[name] = local }
    }

    // MARK: switch and catch

    /// The cases of a `switch` or the clauses of a `do`: the first whose pattern, and `where`, match
    /// the subject has its body run, as the tree evaluator's `firstMatch` says. A clause with no
    /// pattern matches anything, and binds the subject as `anyName` when it has one (a bare `catch`
    /// binds `error`).
    mutating func cases(_ cases: [SwitchCase], _ dispatch: CaseDispatch) throws {
        let (subject, anyName, isSwitch) = (dispatch.subject, dispatch.anyName, dispatch.isSwitch)
        let (whenTaken, noMatch) = (dispatch.whenTaken, dispatch.noMatch)
        // Which case first, then the bodies in order, so that a `fallthrough` goes to the next.
        var bodyJumps: [[Int]] = []
        for switchCase in cases {
            if switchCase.patterns.isEmpty {
                bodyJumps.append([emit(.jump(offset: 0))])
                continue
            }
            let names = Array(Set(switchCase.patterns.flatMap(FrameResolver.names(in:)))).sorted()
            var jumps: [Int] = []
            for (position, pattern) in switchCase.patterns.enumerated() {
                let fail = emit(
                    .match(
                        pattern: try site(pattern, names: names, in: switchCase.body.locals),
                        value: subject,
                        fail: 0
                    )
                )
                var wrong: Int?
                if let condition = switchCase.guardExpr, position == switchCase.patterns.count - 1 {
                    var visible = Scope()
                    for bound in try slots(of: names, in: switchCase.body.locals) {
                        // Not boxed yet: that is done as the body begins.
                        visible.locals[bound.name] = Local(slot: bound.register, mutable: false)
                    }
                    scopes.append(visible)
                    let mark = nextTemporary
                    wrong = emit(.jumpIfWhereFalse(condition: try operand(condition), offset: 0))
                    nextTemporary = mark
                    scopes.removeLast()
                }
                jumps.append(emit(.jump(offset: 0)))
                patch(fail, to: here)
                if let wrong { patch(wrong, to: here) }
            }
            bodyJumps.append(jumps)
        }
        emit(noMatch)

        var ends: [Int] = []
        var pending: [Int] = []
        for (index, switchCase) in cases.enumerated() {
            for jump in bodyJumps[index] + pending { patch(jump, to: here) }
            pending = []
            if let whenTaken { emit(whenTaken) }
            var entering: [String: (slot: Register, mutable: Bool)] = [:]
            if switchCase.patterns.isEmpty {
                if let anyName {
                    let slot = try slots(of: [anyName], in: switchCase.body.locals)[0].register
                    emit(.move(dst: slot, src: subject))
                    bindBox(slot)
                    entering[anyName] = (slot, false)
                }
            } else {
                let names = Set(switchCase.patterns.flatMap(FrameResolver.names(in:)))
                for bound in try slots(of: names.sorted(), in: switchCase.body.locals) {
                    bindBox(bound.register)
                    entering[bound.name] = (bound.register, false)
                }
            }
            try block(switchCase.body, entering: entering)
            ends.append(emit(.jump(offset: 0)))
            if isSwitch {
                pending = breakables[breakables.count - 1].fallthroughs
                breakables[breakables.count - 1].fallthroughs = []
            }
        }
        for jump in ends + pending { patch(jump, to: here) }
    }

    mutating func switchStatement(
        _ node: SwitchStatement,
        _ statement: Statement,
        range: Int32
    ) throws {
        finished(statement)
        let mark = nextTemporary
        let subject = try allocate()
        try expression(node.subject, into: subject)
        breakables.append(Breakable(label: nil, isSwitch: true, scopeDepth: scopes.count))
        try cases(
            node.cases,
            CaseDispatch(subject: subject, isSwitch: true, noMatch: .noMatch(value: subject))
        )
        let context = breakables.removeLast()
        for index in context.breaks { patch(index, to: here) }
        nextTemporary = mark
    }

    // MARK: do, catch and try

    mutating func doCatch(
        _ body: Program,
        _ clauses: [SwitchCase],
        _ statement: Statement,
        range: Int32
    ) throws {
        finished(statement)
        let mark = nextTemporary
        let error = try allocate()
        let guarded = openHandler(catches: .runtimeErrors, register: error, keepsError: true)
        try block(body)
        closeHandler(guarded)
        let end = emit(.jump(offset: 0))
        aimHandler(guarded)
        emit(.at(range: range))
        try cases(
            clauses,
            CaseDispatch(
                subject: error,
                anyName: "error",
                isSwitch: false,
                whenTaken: .caughtTaken,
                noMatch: .rethrow
            )
        )
        patch(end, to: here)
        nextTemporary = mark
    }

    /// `try`, `try?` and `try!` around an expression.
    mutating func attempt(_ operand: Expr, _ kind: TryKind, into destination: Register) throws {
        switch kind {
        case .plain:
            try expression(operand, into: destination)
        case .optional:
            let guarded = openHandler(
                catches: .runtimeErrors,
                keepsError: false,
                isExpression: true
            )
            try expression(operand, into: destination)
            closeHandler(guarded)
            let over = emit(.jump(offset: 0))
            aimHandler(guarded)
            emit(.loadConstant(dst: destination, constant: constant(.nothing)))
            patch(over, to: here)
        case .forced:
            let guarded = openHandler(catches: .runtimeErrors, keepsError: true, isExpression: true)
            try expression(operand, into: destination)
            closeHandler(guarded)
            let over = emit(.jump(offset: 0))
            aimHandler(guarded)
            emit(.fatalize)
            patch(over, to: here)
        }
    }
}
