import Foundation

extension CodeCompiler {
    /// The register an expression's value is in: a local's own, or a temporary it was computed into.
    mutating func operand(_ expression: Expr) throws -> Register {
        if case .local(let local) = expression, !capturedSlots.contains(local.slot),
            !weakSlots.contains(local.slot)
        {
            return Register(local.slot)
        }
        if case .variable(let name) = expression, let local = lookup(name), !local.boxed,
            !weakSlots.contains(Int(local.slot))
        {
            return local.slot
        }
        // The value of `self` is read where it is.
        if case .variable("self") = expression, !code.selfStorage.holdsCell,
            let register = code.selfRegister, lookup("self") == nil
        {
            return register
        }
        let result = try allocate()
        try self.expression(expression, into: result)
        return result
    }

    mutating func expression(_ expression: Expr, into destination: Register) throws {
        let mark = nextTemporary
        defer { nextTemporary = mark }
        switch expression {
        case .literal(let value):
            emit(.loadConstant(dst: destination, constant: constant(value)))
        case .local(let local):
            read(Register(local.slot), boxed: capturedSlots.contains(local.slot), into: destination)
        case .variable(let name):
            variable(name, into: destination)
        case .binary(let op, let lhs, let rhs):
            // A `.case` operand takes its enum from the other side, and a range is a value of its own:
            // the tree evaluator's.
            if Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs)
                || op == .closedRange || op == .halfOpenRange
            {
                treeExpression(expression, into: destination)
            } else {
                try binary(op, lhs, rhs, into: destination)
            }
        case .unary(let op, let operand):
            let source = try self.operand(operand)
            emit(.unary(op: op, dst: destination, src: source))
        case .annotated(let inner, let type):
            try self.expression(inner, into: destination)
            code.types.append(type)
            emit(
                .conversions(
                    .conform(dst: destination, src: destination, type: UInt32(code.types.count - 1))
                )
            )
        case .member(let base, _) where isConstant(base):
            code.expressions.append(expression)
            emit(
                .fallback(
                    .evaluate(dst: destination, expression: UInt32(code.expressions.count - 1))
                )
            )
        case .member(let base, let name):
            let held = try operand(base)
            code.names.append(name)
            code.methods.append(
                MethodSite(name: name, labels: [], mayMutate: false, isGetter: true)
            )
            emit(
                .loadMember(
                    dst: destination,
                    base: held,
                    name: UInt32(code.names.count - 1),
                    site: UInt32(code.methods.count - 1)
                )
            )
        case .string(let parts):
            try interpolation(parts, into: destination)
        case .closure(let literal):
            try closure(literal, into: destination)
        case .await(let target, _):
            // The interpreter waits at every wait, so `await f()` is what `f()` gives.
            try self.expression(target, into: destination)
        case .attempt(let operand, let kind):
            try attempt(operand, kind, into: destination)
        case .bridged where try fastMember(expression, into: destination):
            break
        case .bridged where try bridgedCall(expression, into: destination):
            break
        case .call(.member(.variable("super"), let name), let arguments)
        where try superMethod(name, arguments, expression, into: destination):
            break
        case .call(.member(let base, let name), let arguments)
        where try method(base, name, arguments, expression, into: destination):
            break
        case .call(let callee, let arguments):
            if !(try call(callee, arguments, into: destination)) {
                treeExpression(expression, into: destination)
            }
        case .ifExpression(let node):
            if !(try conditional(node, into: destination)) {
                treeExpression(expression, into: destination)
            }
        default:
            if !(try construction(expression, into: destination)) {
                // What the VM does not compile itself: constructors, key paths, subscripts with
                // several arguments, and the rest.
                treeExpression(expression, into: destination)
            }
        }
    }

    /// A name the frame resolver left in what it does not look into (a `where`), which may be a
    /// local, `self`, or a global.
    private mutating func variable(_ name: String, into destination: Register) {
        if let local = lookup(name) {
            read(local.slot, boxed: local.boxed, into: destination)
        } else if name == "self", let register = code.selfRegister {
            emit(
                code.selfStorage.holdsCell
                    ? .captures(.loadCell(dst: destination, box: register))
                    : .move(dst: destination, src: register)
            )
        } else {
            code.globals.append(GlobalSite(name: name))
            emit(.globals(.loadGlobal(dst: destination, site: UInt32(code.globals.count - 1))))
        }
    }

    /// `"…\(x)…"`: the values are made here, left to right, so that a call among them is the loop's.
    private mutating func interpolation(
        _ parts: [StringPart],
        into destination: Register
    ) throws {
        let first = Register(nextTemporary)
        var pieces: [StringSite.Piece] = []
        var count = 0
        for part in parts {
            switch part {
            case .literal(let text): pieces.append(.text(text))
            case .expression(let value):
                try self.expression(value, into: try allocate())
                pieces.append(.value(count))
                count += 1
            }
        }
        code.strings.append(StringSite(pieces: pieces))
        emit(
            .conversions(
                .interpolate(dst: destination, site: UInt32(code.strings.count - 1), first: first)
            )
        )
    }

    /// The expressions that make a value of others, ask what one is, or index one: literals of
    /// collections, `x!`, casts, and subscripts. False if it is not one of those, or is too large.
    private mutating func construction(
        _ expression: Expr,
        into destination: Register
    ) throws -> Bool {
        switch expression {
        case .list(let items) where items.count <= 200:
            let first = Register(nextTemporary)
            for item in items { try self.expression(item, into: try allocate()) }
            emit(
                .collections(
                    .makeList(dst: destination, first: first, count: Register(items.count))
                )
            )
        case .record(let entries) where entries.count <= 100:
            let first = Register(nextTemporary)
            for entry in entries {
                try self.expression(entry.key, into: try allocate())
                try self.expression(entry.value, into: try allocate())
            }
            emit(
                .collections(
                    .makeDictionary(dst: destination, first: first, count: Register(entries.count))
                )
            )
        case .tuple(let elements) where elements.count <= 200:
            let first = Register(nextTemporary)
            for element in elements { try self.expression(element.value, into: try allocate()) }
            code.tuples.append(elements.map(\.label))
            emit(
                .collections(
                    .makeTuple(dst: destination, site: UInt32(code.tuples.count - 1), first: first)
                )
            )
        case .index(let base, let key):
            let held = try operand(base)
            emit(.collections(.index(dst: destination, base: held, key: try operand(key))))
        case .indexDefault(let base, let key, let fallback):
            let held = try operand(base)
            let fast = emit(
                .collections(
                    .dictionaryValue(dst: destination, base: held, key: try operand(key), offset: 0)
                )
            )
            try self.expression(fallback, into: destination)
            patch(fast, to: here)
        case .forceUnwrap(let inner):
            try self.expression(inner, into: destination)
            code.names.append(
                "\(SwiftPrinter().source(inner)) is nil, but '!' needs a value"
            )
            emit(
                .conversions(.requireValue(src: destination, message: UInt32(code.names.count - 1)))
            )
        case .voidValue(let inner):
            try self.expression(inner, into: destination)
            emit(.loadConstant(dst: destination, constant: constant(Value(record: Value.Record()))))
        case .described(let inner, let type):
            let source = try operand(inner)
            code.types.append(type)
            emit(
                .conversions(
                    .describe(dst: destination, src: source, type: UInt32(code.types.count - 1))
                )
            )
        case .cast(let inner, let type, let kind):
            let source = try operand(inner)
            code.types.append(type)
            emit(
                .conversions(
                    .cast(
                        dst: destination,
                        src: source,
                        type: UInt32(code.types.count - 1),
                        kind: kind
                    )
                )
            )
        default:
            return false
        }
        return true
    }

    /// A jump taken when `condition` is false, to be patched: a comparison with a small integer is one
    /// instruction.
    mutating func jumpUnless(_ condition: Expr) throws -> Int {
        if case .binary(let op, let lhs, .literal(let literal)) = condition,
            [.less, .lessEqual, .greater, .greaterEqual, .equal, .notEqual].contains(op),
            case .int(let number) = literal.storage, let small = Int32(exactly: number),
            !Interpreter.isCaseLiteral(lhs)
        {
            let register = try operand(lhs)
            return emit(.jumpUnlessCompare(op: op, lhs: register, value: small, offset: 0))
        }
        return emit(.jumpIfFalse(condition: try operand(condition), offset: 0))
    }

    /// The name a variable expression is, or an empty one.
    func selfName(of expression: Expr) -> String {
        if case .variable(let name) = expression { return name }
        return ""
    }

    /// `name` is `self` in a body that keeps its cell in a register.
    func namesSelfRegister(_ name: String) -> Bool {
        name == "self" && code.selfRegister != nil
    }

    /// Whether an expression changes nothing and calls nothing, so that making it twice (once for
    /// the fast member, and again if that does not apply) is the same as once.
    func isPure(_ value: Expr) -> Bool {
        switch value {
        case .literal, .local: true
        case .variable(let name): lookup(name) != nil || namesSelfRegister(name)
        case .unary(_, let operand): isPure(operand)
        case .binary(let op, let lhs, let rhs):
            op != .closedRange && op != .halfOpenRange && isPure(lhs) && isPure(rhs)
        default: false
        }
    }

    /// Whether an expression names only globals and types, so that the tree evaluator can run it
    /// without the registers: `Oops.bad`, `Direction.north`.
    func isConstant(_ value: Expr) -> Bool {
        switch value {
        case .literal: true
        case .variable(let name): lookup(name) == nil && !namesSelfRegister(name)
        case .unary(_, let operand): isConstant(operand)
        case .binary(_, let lhs, let rhs): isConstant(lhs) && isConstant(rhs)
        case .member(let base, _): isConstant(base)
        default: false
        }
    }

    private mutating func binary(
        _ op: BinaryOperator,
        _ lhs: Expr,
        _ rhs: Expr,
        into destination: Register
    ) throws {
        switch op {
        case .and, .or:
            try expression(lhs, into: destination)
            let settled = emit(.shortCircuit(op: op, register: destination, offset: 0))
            try expression(rhs, into: destination)
            emit(.needBool(op: op, register: destination))
            patch(settled, to: here)
        case .coalesce:
            try expression(lhs, into: destination)
            let present = emit(.jumpIfNotNil(register: destination, offset: 0))
            try expression(rhs, into: destination)
            patch(present, to: here)
        case .closedRange, .halfOpenRange:
            preconditionFailure("a range is made by the tree evaluator")
        default:
            let a = try operand(lhs)
            if case .literal(let literal) = rhs, case .int(let number) = literal.storage,
                let small = Int32(exactly: number)
            {
                emit(.binaryImmediate(op: op, dst: destination, lhs: a, value: small))
                return
            }
            let b = try operand(rhs)
            emit(.binary(op: op, dst: destination, lhs: a, rhs: b))
        }
    }

    /// A local's value into `destination`, out of its cell when a closure shares it.
    private mutating func read(_ slot: Register, boxed: Bool, into destination: Register) {
        if boxed {
            emit(.captures(.loadCell(dst: destination, box: slot)))
        } else if slot != destination {
            emit(.move(dst: destination, src: slot))
        }
        if weakSlots.contains(Int(slot)) { emit(.captures(.derefWeak(register: destination))) }
    }

    /// A closure: made when this runs, of the cells of the locals it names and the values its
    /// capture list takes.
    private mutating func closure(_ literal: ClosureLiteral, into destination: Register) throws {
        var cells: [CapturedCell] = []
        var others: [String] = []
        let taken = Set(literal.captures.map(\.name))
        for name in literal.names.names.subtracting(taken).sorted() {
            guard let local = lookup(name) else {
                others.append(name)
                continue
            }
            guard local.boxed else { throw Unsupported("a captured local that is not in a cell") }
            cells.append(CapturedCell(name: name, register: local.slot, mutable: local.mutable))
        }
        var captures: [TakenValue] = []
        for capture in literal.captures {
            let register = try allocate()
            try expression(capture.value, into: register)
            captures.append(
                TakenValue(
                    name: capture.name,
                    register: register,
                    isWeak: capture.isWeak,
                    isUnowned: capture.isUnowned
                )
            )
        }
        code.closures.append(
            ClosureSite(literal: literal, cells: cells, others: others, captures: captures)
        )
        emit(.captures(.makeClosure(dst: destination, site: UInt32(code.closures.count - 1))))
    }
}
