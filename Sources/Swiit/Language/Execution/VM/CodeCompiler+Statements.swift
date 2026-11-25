import Foundation

extension CodeCompiler {
    // MARK: Blocks

    /// The statements of a block, with its `defer`s: each is registered where it is reached, and
    /// they run, last first, as the block ends however it ends. Normal ends and `break`, `continue`
    /// and `return` run them in line; an error is sent to code after the block that runs them and
    /// throws it again.
    mutating func contents(of program: Program) throws {
        let defers = program.statements.compactMap { statement -> Program? in
            if case .deferBlock(let body) = statement { body } else { nil }
        }
        guard !defers.isEmpty else {
            try statements(of: program)
            return
        }
        guard defers.count <= 60 else { throw Unsupported("many defers in a block") }
        let mark = nextTemporary
        defer { nextTemporary = mark }
        let mask = try allocate()
        scopes[scopes.count - 1].defers = defers
        scopes[scopes.count - 1].deferMask = mask
        emit(.loadConstant(dst: mask, constant: constant(.int(0))))
        let guarded = openHandler(catches: .everything, keepsError: true)
        try statements(of: program)
        closeHandler(guarded)
        try emitCleanup(of: scopes.count - 1)
        let over = emit(.jump(offset: 0))
        aimHandler(guarded)
        try emitCleanup(of: scopes.count - 1)
        emit(.rethrow)
        patch(over, to: here)
    }

    mutating func statements(of program: Program) throws {
        for (index, statement) in program.statements.enumerated() {
            let range = range(of: program, index)
            try compile(statement, range: range)
        }
    }

    /// A block: a scope of its own, whose locals are cleared when it ends.
    mutating func block(
        _ program: Program,
        entering names: [String: (slot: Register, mutable: Bool)] = [:]
    ) throws {
        guard let locals = program.locals else { throw Unsupported("a block run by name") }
        var scope = Scope()
        for (name, entered) in names {
            scope.locals[name] = local(entered.slot, mutable: entered.mutable)
        }
        if let first = locals.map(\.slot).min(), let last = locals.map(\.slot).max() {
            scope.cleared = (Register(first), Register(last - first + 1))
        }
        scopes.append(scope)
        try contents(of: program)
        if let cleared = scope.cleared {
            emit(.clear(first: cleared.first, count: cleared.count))
        }
        scopes.removeLast()
    }

    /// The deferred blocks of a scope, those it has reached, last first. Each runs where an error in
    /// it is told to the host and does not go on, and the host is not told its statements.
    mutating func emitCleanup(of scopeIndex: Int) throws {
        let scope = scopes[scopeIndex]
        guard !scope.defers.isEmpty, let mask = scope.deferMask else { return }
        emit(.quietBegin)
        for (bit, body) in scope.defers.enumerated().reversed() {
            let skip = emit(.jumpIfNotDeferred(register: mask, bit: UInt8(bit), offset: 0))
            let guarded = openHandler(catches: .everything, keepsError: true)
            try block(body)
            closeHandler(guarded)
            let done = emit(.jump(offset: 0))
            aimHandler(guarded)
            emit(.reportDeferred)
            patch(done, to: here)
            patch(skip, to: here)
        }
        emit(.quietEnd)
    }

    /// What leaving the scopes from `depth` out, by `break`, `continue`, `fallthrough` or `return`,
    /// does on the way: each block runs its deferred blocks, then clears its locals.
    mutating func emitExit(downTo depth: Int, clearing: Bool) throws {
        for index in (depth..<scopes.count).reversed() {
            try emitCleanup(of: index)
            if clearing, let cleared = scopes[index].cleared {
                emit(.clear(first: cleared.first, count: cleared.count))
            }
        }
    }

    // MARK: Statements

    mutating func compile(_ statement: Statement, range: Int32) throws {
        switch statement {
        case .function, .enumDecl, .structDecl, .classDecl, .protocolDecl, .typeExtension,
            .extensionDecl, .operatorDeclaration:
            throw Unsupported("a declaration in a body")
        case .deferBlock:
            // Not a step: the tree evaluator only collects it. It is registered where it is reached.
            let scope = scopes.count - 1
            guard let mask = scopes[scope].deferMask else { throw Unsupported("a defer") }
            emit(.deferMark(register: mask, bit: UInt8(scopes[scope].deferred)))
            scopes[scope].deferred += 1
            return
        default:
            emit(.step(range: range))
        }
        try compileCounted(statement, range: range)
    }

    private mutating func compileCounted(_ statement: Statement, range: Int32) throws {
        switch statement {
        case .declareLocal(let local, let mutable, let value):
            let slot = Register(local.slot)
            if case .call(.variable(InternalName.weak), _) = value { weakSlots.insert(local.slot) }
            try expression(value, into: slot)
            bindBox(slot)
            scopes[scopes.count - 1].locals[local.name] = self.local(slot, mutable: mutable)
            finished(statement)
        case .declare(let name, _, let value) where name == "_":
            // `_ = value`: made, and let go.
            let mark = nextTemporary
            try expression(value, into: try allocate())
            nextTemporary = mark
            finished(statement)
        case .assign(let assignment):
            try assign(assignment, statement)
            finished(statement)
        case .expression(let value):
            let mark = nextTemporary
            let result = try allocate()
            try expression(value, into: result)
            emit(.finished(statement: stored(statement), value: result))
            nextTemporary = mark
        case .returnStatement(let value):
            let mark = nextTemporary
            // The result is worked out before the deferred blocks run, which may change a local
            // it is: so it is copied when any will.
            let deferring = scopes.contains { !$0.defers.isEmpty }
            let result = try value.map { value -> Register in
                guard deferring else { return try operand(value) }
                let copy = try allocate()
                try expression(value, into: copy)
                return copy
            }
            try emitExit(downTo: 0, clearing: false)
            if code.isFailable { emit(.failInit(result ?? Register.max)) }
            try emitReturn(result)
            nextTemporary = mark
        case .throwStatement(let value):
            let mark = nextTemporary
            emit(.throwValue(try operand(value)))
            nextTemporary = mark
        case .ifStatement(let node):
            try ifStatement(node, statement)
        case .guardStatement(let condition, let otherwise, let locals):
            try guardStatement(condition, otherwise, locals, range: range)
        case .switchStatement(let node):
            try switchStatement(node, statement, range: range)
        case .doCatch(let body, let clauses):
            try doCatch(body, clauses, statement, range: range)
        case .whileLoop(let loop):
            try whileLoop(loop, statement, range: range)
        case .forLoop(let loop):
            try forLoop(loop, statement)
        case .breakStatement(let label):
            try leave(label, isBreak: true)
        case .continueStatement(let label):
            try leave(label, isBreak: false)
        case .fallthroughStatement:
            try fallThrough()
        default:
            throw Unsupported("a statement the VM does not run yet")
        }
    }

    mutating func stored(_ statement: Statement) -> UInt32 {
        code.statements.append(statement)
        return UInt32(code.statements.count - 1)
    }

    /// Tells the host a statement without a value finished.
    mutating func finished(_ statement: Statement) {
        emit(.finished(statement: stored(statement), value: Register.max))
    }

    /// `x = v` and `x += v` of a local, or of a variable that is not (a global, or one a closure
    /// captured) which the tree evaluator assigns by name.
    private mutating func assign(_ assignment: Assignment, _ statement: Statement) throws {
        // Through a path (`p.x = 1`, `xs[i] += 1`), or to a constant, which fails as it does there: the
        // tree evaluator's, which finds the root in a frame of the locals the statement mentions.
        let known = lookup(assignment.root)
        // A weak variable stays weak when it is assigned, which the tree evaluator sees to.
        let isWeak = known.map { weakSlots.contains(Int($0.slot)) } ?? false
        guard assignment.path.isEmpty, known?.mutable ?? true, !isWeak else {
            treeStatement(statement, roots: [assignment.root])
            return
        }
        let mark = nextTemporary
        let value = try allocate()
        try expression(assignment.value, into: value)
        if let local = known {
            if local.boxed {
                if let op = assignment.op {
                    emit(.assignCell(box: local.slot, op: op, value: value))
                } else {
                    emit(.storeCell(box: local.slot, src: value))
                }
            } else {
                emit(.assign(local: local.slot, op: assignment.op, value: value))
            }
        } else {
            code.assignments.append(assignment)
            emit(.assignByName(site: UInt32(code.assignments.count - 1), value: value))
        }
        nextTemporary = mark
    }

    // MARK: Loops

    private mutating func whileLoop(_ loop: WhileLoop, _ statement: Statement, range: Int32) throws
    {
        finished(statement)
        if loop.isRepeat {
            let head = here
            breakables.append(
                Breakable(label: loop.label, isSwitch: false, scopeDepth: scopes.count)
            )
            emit(.tick)
            try block(loop.body)
            let context = breakables.removeLast()
            for index in context.continues { patch(index, to: here) }
            emit(.at(range: range))
            let mark = nextTemporary
            let test = try operand(loop.condition)
            let again = emit(.jumpIfTrue(condition: test, offset: 0))
            patch(again, to: head)
            nextTemporary = mark
            for index in context.breaks { patch(index, to: here) }
            return
        }
        let head = here
        emit(.at(range: range))
        let mark = nextTemporary
        let exit = try jumpUnless(loop.condition)
        nextTemporary = mark
        breakables.append(
            Breakable(
                label: loop.label,
                isSwitch: false,
                scopeDepth: scopes.count,
                continueTarget: head
            )
        )
        emit(.tick)
        try block(loop.body)
        jump(to: head)
        let context = breakables.removeLast()
        patch(exit, to: here)
        for index in context.breaks { patch(index, to: here) }
    }

    private mutating func forLoop(_ loop: ForLoop, _ statement: Statement) throws {
        if case .binary(let op, let lower, let upper) = loop.sequence,
            op == .closedRange || op == .halfOpenRange
        {
            try rangeLoop(loop, op, lower, upper, statement)
        } else {
            try elementsLoop(loop, statement)
        }
    }

    /// `for x in a..<b`: counted without making the range.
    private mutating func rangeLoop(
        _ loop: ForLoop,
        _ op: BinaryOperator,
        _ lower: Expr,
        _ upper: Expr,
        _ statement: Statement
    ) throws {
        var entering: [String: (slot: Register, mutable: Bool)] = [:]
        var variable: Register?
        switch loop.pattern {
        case .wildcard: break
        case .binding(let name, let mutable):
            guard let local = loop.body.locals?.first(where: { $0.name == name }) else {
                throw Unsupported("a for variable without a slot")
            }
            variable = Register(local.slot)
            entering[name] = (Register(local.slot), mutable)
        default: throw Unsupported("a for with a pattern")
        }
        finished(statement)
        let mark = nextTemporary
        let counter = try allocate()
        _ = try allocate()
        let scratch = try allocate()
        let bounds = nextTemporary
        let first = try operand(lower)
        let last = try operand(upper)
        emit(.rangeStart(op: op, counter: counter, lower: first, upper: last))
        nextTemporary = bounds
        let head = here
        let next = emit(.rangeNext(counter: counter, variable: variable ?? scratch, exit: 0))
        if let variable { bindBox(variable) }
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
        patch(next, to: here)
        for index in context.breaks { patch(index, to: here) }
        nextTemporary = mark
    }

    /// `for x in xs`: of a collection, a string, a dictionary, or what has an iterator. A pattern that
    /// is not a name (`(i, x)`) is matched to each element as the runtime matches one.
    private mutating func elementsLoop(_ loop: ForLoop, _ statement: Statement) throws {
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
        let iterator = try allocate()
        let element = try allocate()
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
            mismatch = emit(.match(pattern: matched.site, value: element, fail: 0))
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

    /// `break` and `continue`: the blocks left run their deferred blocks and clear their locals first,
    /// as ending a block does. An unlabeled `break` leaves the nearest loop or switch, an unlabeled
    /// `continue` the nearest loop.
    private mutating func leave(_ label: String?, isBreak: Bool) throws {
        guard
            let index = breakables.lastIndex(where: {
                label == nil ? (isBreak || !$0.isSwitch) : $0.label == label
            })
        else {
            throw Unsupported("a break or continue outside a loop")
        }
        try emitExit(downTo: breakables[index].scopeDepth, clearing: true)
        if isBreak {
            breakables[index].breaks.append(emit(.jump(offset: 0)))
        } else if let target = breakables[index].continueTarget {
            jump(to: target)
        } else {
            breakables[index].continues.append(emit(.jump(offset: 0)))
        }
    }

    /// `fallthrough`: on into the next case's body, with nothing bound.
    private mutating func fallThrough() throws {
        guard let index = breakables.lastIndex(where: { $0.isSwitch }) else {
            throw Unsupported("a fallthrough outside a switch")
        }
        try emitExit(downTo: breakables[index].scopeDepth, clearing: true)
        breakables[index].fallthroughs.append(emit(.jump(offset: 0)))
    }
}
