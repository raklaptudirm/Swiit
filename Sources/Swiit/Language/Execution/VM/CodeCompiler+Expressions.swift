import Foundation

extension CodeCompiler {
    /// The register an expression's value is in: a local's own, or a temporary it was computed into.
    mutating func operand(_ expression: Expr) throws -> Register {
        if case .local(let local) = expression { return Register(local.slot) }
        if case .variable(let name) = expression, let local = lookup(name) { return local.slot }
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
            if Register(local.slot) != destination {
                emit(.move(dst: destination, src: Register(local.slot)))
            }
        case .variable(let name):
            // A name the frame resolver left in what it does not look into (a `where`) may be a local.
            if let local = lookup(name) {
                if local.slot != destination { emit(.move(dst: destination, src: local.slot)) }
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

    private mutating func call(
        _ callee: Expr,
        _ arguments: [Argument],
        into destination: Register
    ) throws {
        var named = callee
        if case .chosen(let inner, _) = callee { named = inner }
        var name: String?
        switch named {
        case .variable(let called) where lookup(called) == nil: name = called
        case .member(let base, _) where isConstant(base): break
        default: throw Unsupported("a call of something but a global name or a member of one")
        }
        for argument in arguments {
            switch argument.value {
            case .inoutArgument, .caseLiteral: throw Unsupported("an inout or .case argument")
            default: break
            }
        }
        let first = Register(nextTemporary)
        for argument in arguments {
            let register = try allocate()
            try expression(argument.value, into: register)
        }
        code.callSites.append(CallSite(name: name, callee: callee, labels: arguments.map(\.label)))
        emit(.call(dst: destination, site: UInt32(code.callSites.count - 1), arguments: first))
    }
}
