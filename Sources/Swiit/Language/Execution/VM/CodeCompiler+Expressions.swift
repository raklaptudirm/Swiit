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
                code.globals.append(GlobalSite(name: name))
                emit(.loadGlobal(dst: destination, site: UInt32(code.globals.count - 1)))
            }
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
            emit(.conform(dst: destination, src: destination, type: UInt32(code.types.count - 1)))
        case .member(let base, _) where isConstant(base):
            code.expressions.append(expression)
            emit(.evaluate(dst: destination, expression: UInt32(code.expressions.count - 1)))
        case .closure(let literal):
            try closure(literal, into: destination)
        case .await(let target, _):
            // The interpreter waits at every wait, so `await f()` is what `f()` gives.
            try self.expression(target, into: destination)
        case .attempt(let operand, let kind):
            try attempt(operand, kind, into: destination)
        case .bridged where try fastMember(expression, into: destination):
            break
        case .call(let callee, let arguments):
            if !(try call(callee, arguments, into: destination)) {
                treeExpression(expression, into: destination)
            }
        default:
            // What the VM does not compile itself: members, subscripts, constructors, casts,
            // interpolation, literals of collections, key paths, and the rest.
            treeExpression(expression, into: destination)
        }
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

    /// Whether an expression changes nothing and calls nothing, so that making it twice (once for
    /// the fast member, and again if that does not apply) is the same as once.
    func isPure(_ value: Expr) -> Bool {
        switch value {
        case .literal, .local: true
        case .variable(let name): lookup(name) != nil
        case .unary(_, let operand): isPure(operand)
        case .binary(let op, let lhs, let rhs):
            op != .closedRange && op != .halfOpenRange && isPure(lhs) && isPure(rhs)
        default: false
        }
    }

    /// A member of an `Array` or a `String` held in a local, made by `fastMember` where the kinds fit
    /// and by the tree evaluator, which follows it, where they do not. False if it is not one of those.
    mutating func fastMember(_ expression: Expr, into destination: Register) throws -> Bool {
        guard case .bridged(let type, let member, let receiver?, let arguments) = expression,
            let found = bridged[type]?.lowered, member < found.count
        else { return false }
        let named = found[member]
        let kind: FastMember
        switch (type, named.name, named.kind, arguments.count) {
        case ("Array", "append", .method, 1) where named.isMutating: kind = .append
        case ("Array", "count", .property, 0): kind = .listCount
        case ("Array", "subscript", .method, 1): kind = .element
        case ("String", "count", .property, 0): kind = .stringCount
        default: return false
        }
        var held: Local?
        switch receiver {
        case .local(let local): held = lookup(local.name)
        case .variable(let name): held = lookup(name)
        default: break
        }
        guard let held, !held.boxed, !weakSlots.contains(Int(held.slot)),
            kind != .append || held.mutable,
            arguments.allSatisfy({ $0.label == nil && isPure($0.value) })
        else { return false }
        let mark = nextTemporary
        let argument = try arguments.first.map { try operand($0.value) } ?? held.slot
        let fast = emit(
            .fastMember(
                kind: kind,
                dst: destination,
                receiver: held.slot,
                argument: argument,
                offset: 0
            )
        )
        nextTemporary = mark
        treeExpression(expression, into: destination)
        patch(fast, to: here)
        return true
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
            emit(.loadCell(dst: destination, box: slot))
        } else if slot != destination {
            emit(.move(dst: destination, src: slot))
        }
        if weakSlots.contains(Int(slot)) { emit(.derefWeak(register: destination)) }
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

    /// A call the VM makes itself: of a global name, a member of a global, or a local. False for any
    /// other (a call on a value, an `inout` argument that is not a local, a `.case` argument), which the
    /// tree evaluator makes.
    private mutating func call(
        _ callee: Expr,
        _ arguments: [Argument],
        into destination: Register
    ) throws -> Bool {
        var named = callee
        if case .chosen(let inner, _) = callee { named = inner }
        enum Target {
            case name(String)
            case member
            case value(Register)
        }
        for argument in arguments {
            switch argument.value {
            case .caseLiteral: return false
            case .inoutArgument(let place):
                switch place {
                case .local: break
                case .variable(let name) where lookup(name) != nil: break
                default: return false
                }
            default: break
            }
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
        default: return false
        }
        // The places `&x` names get what the callee leaves in its `inout` parameters.
        var places: [InoutPlace] = []
        var values: [Expr] = []
        for argument in arguments {
            switch argument.value {
            case .caseLiteral: return false
            case .inoutArgument(let place):
                var local: (slot: Register, boxed: Bool)?
                if case .local(let named) = place {
                    local = (Register(named.slot), capturedSlots.contains(named.slot))
                } else if case .variable(let name) = place, let found = lookup(name) {
                    local = (found.slot, found.boxed)
                }
                guard let local else { return false }
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
        guard !places.isEmpty else { return true }
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
        return true
    }
}

/// A variable passed with `&`, which gets what the callee leaves in its `inout` parameter.
private struct InoutPlace {
    let index: Int
    let slot: Register
    let boxed: Bool
}
