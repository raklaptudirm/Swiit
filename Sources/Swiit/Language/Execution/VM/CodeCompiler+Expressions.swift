import Foundation

extension CodeCompiler {
    /// The register an expression's value is in: a local's own, or a temporary it was computed into.
    mutating func operand(_ expression: Expr) throws -> Register {
        if case .local(let local) = expression, !capturedSlots.contains(local.slot) {
            return Register(local.slot)
        }
        if case .variable(let name) = expression, let local = lookup(name), !local.boxed {
            return local.slot
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
            // A name the frame resolver left in what it does not look into (a `where`) may be a local.
            if let local = lookup(name) {
                read(local.slot, boxed: local.boxed, into: destination)
            } else {
                code.names.append(name)
                emit(.loadVariable(dst: destination, name: UInt32(code.names.count - 1)))
            }
        case .binary(let op, let lhs, let rhs):
            try binary(op, lhs, rhs, into: destination)
        case .unary(let op, let operand):
            let source = try self.operand(operand)
            emit(.unary(op: op, dst: destination, src: source))
        case .annotated(let inner, let type):
            try self.expression(inner, into: destination)
            code.types.append(type)
            emit(.conform(dst: destination, src: destination, type: UInt32(code.types.count - 1)))
        case .member(let base, _) where isConstant(base):
            code.expressions.append(expression)
            emit(.evaluate(dst: destination, expression: UInt32(code.expressions.count - 1)))
        case .closure(let literal):
            try closure(literal, into: destination)
        case .attempt(let operand, let kind):
            try attempt(operand, kind, into: destination)
        case .call(let callee, let arguments):
            try call(callee, arguments, into: destination)
        default:
            throw Unsupported("an expression the VM does not run yet")
        }
    }

    /// Whether an expression names only globals and types, so that the tree evaluator can run it
    /// without the registers: `Oops.bad`, `Direction.north`.
    func isConstant(_ value: Expr) -> Bool {
        switch value {
        case .literal: true
        case .variable(let name): lookup(name) == nil
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
        if Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs) {
            throw Unsupported("a .case operand")
        }
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
            throw Unsupported("a range as a value")
        default:
            let a = try operand(lhs)
            let b = try operand(rhs)
            emit(.binary(op: op, dst: destination, lhs: a, rhs: b))
        }
    }

    /// A local's value into `destination`, out of its cell when a closure shares it.
    private mutating func read(_ slot: Register, boxed: Bool, into destination: Register) {
        if boxed {
            emit(.loadCell(dst: destination, box: slot))
        } else if slot != destination {
            emit(.move(dst: destination, src: slot))
        }
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
        emit(.makeClosure(dst: destination, site: UInt32(code.closures.count - 1)))
    }

    private mutating func call(
        _ callee: Expr,
        _ arguments: [Argument],
        into destination: Register
    ) throws {
        var named = callee
        if case .chosen(let inner, _) = callee { named = inner }
        enum Target {
            case name(String)
            case member
            case value(Register)
        }
        let target: Target
        switch named {
        case .variable(let called) where lookup(called) == nil: target = .name(called)
        case .member(let base, _) where isConstant(base): target = .member
        case .local, .variable:
            // A closure in a variable, or a parameter of function type.
            let held = try allocate()
            try expression(named, into: held)
            target = .value(held)
        default: throw Unsupported("a call of something but a name, a member of one, or a local")
        }
        // The places `&x` names get what the callee leaves in its `inout` parameters.
        var places: [InoutPlace] = []
        var values: [Expr] = []
        for argument in arguments {
            switch argument.value {
            case .caseLiteral: throw Unsupported("a .case argument")
            case .inoutArgument(let place):
                var local: (slot: Register, boxed: Bool)?
                if case .local(let named) = place {
                    local = (Register(named.slot), capturedSlots.contains(named.slot))
                } else if case .variable(let name) = place, let found = lookup(name) {
                    local = (found.slot, found.boxed)
                }
                guard let local else { throw Unsupported("an inout argument that is not a local") }
                places.append(InoutPlace(index: places.count, slot: local.slot, boxed: local.boxed))
                values.append(place)
            default: values.append(argument.value)
            }
        }
        let first = Register(nextTemporary)
        for value in values {
            let register = try allocate()
            try expression(value, into: register)
        }
        var name: String?
        if case .name(let called) = target { name = called }
        code.callSites.append(CallSite(name: name, callee: callee, labels: arguments.map(\.label)))
        let site = UInt32(code.callSites.count - 1)
        if case .value(let held) = target {
            emit(.callValue(dst: destination, callee: held, site: site, arguments: first))
        } else {
            emit(.call(dst: destination, site: site, arguments: first))
        }
        guard !places.isEmpty else { return }
        for place in places {
            if place.boxed {
                let outcome = try allocate()
                emit(.takeInout(dst: outcome, index: UInt16(place.index)))
                emit(.storeCell(box: place.slot, src: outcome))
            } else {
                emit(.takeInout(dst: place.slot, index: UInt16(place.index)))
            }
        }
        emit(.finishInout)
    }
}

/// A variable passed with `&`, which gets what the callee leaves in its `inout` parameter.
private struct InoutPlace {
    let index: Int
    let slot: Register
    let boxed: Bool
}
