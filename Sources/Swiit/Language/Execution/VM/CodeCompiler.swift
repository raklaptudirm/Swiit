import Foundation

/// A body the compiler does not handle (yet): the function it is in keeps running on the tree
/// evaluator. `reason` says what stopped it, for the progress count.
struct Unsupported: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Compiles a function body to `Code`. It takes what the tree evaluator runs, after the checker and
/// the frame resolver, and handles the part of the language slice 1 of `Docs/vm.md` names: locals in
/// registers, arithmetic and comparison, `if`, `while`, `for` over a range, `break` and `continue`,
/// calls by name, `return`. Anything else throws `Unsupported`.
struct CodeCompiler {
    private struct Local {
        let slot: Register
        let mutable: Bool
    }

    private struct Scope {
        var locals: [String: Local] = [:]
        /// The registers its block declares, cleared when the block ends.
        var cleared: (first: Register, count: Register)?
    }

    private struct Loop {
        let label: String?
        /// How many scopes were open outside the loop's body.
        let scopeDepth: Int
        /// Where `continue` goes, when that is known before the body is compiled.
        var continueTarget: Int?
        var continues: [Int] = []
        var breaks: [Int] = []
    }

    private var code = Code()
    private var scopes: [Scope] = []
    private var loops: [Loop] = []
    private var nextTemporary = 0
    private var highest = 0

    /// The code for `function`, or nil when it is not one the VM runs.
    static func compile(_ function: Function) -> Code? {
        guard function.isCompilable, case .swiit(let body) = function.body,
            let frameSize = body.frameSize
        else { return nil }
        var compiler = CodeCompiler()
        do {
            try compiler.function(function, body, frameSize: frameSize)
        } catch {
            return nil
        }
        return compiler.code
    }

    private mutating func function(_ function: Function, _ body: Program, frameSize: Int) throws {
        nextTemporary = frameSize
        highest = max(frameSize, function.parameters.count) - 1
        code.parameterCount = function.parameters.count
        code.parameterKinds = function.parameters.map { ParameterKind($0.type) }
        var parameters = Scope()
        for (slot, parameter) in function.parameters.enumerated() where parameter.name != "_" {
            parameters.locals[parameter.name] = Local(slot: Register(slot), mutable: false)
        }
        scopes = [parameters]
        if let expression = function.implicitReturn {
            code.isImplicitReturn = true
            let result = try operand(expression)
            emit(.returnValue(result))
        } else {
            try statements(of: body)
            emit(.returnNothing)
        }
        code.frameSize = highest + 1
    }

    // MARK: Emitting

    @discardableResult
    private mutating func emit(_ instruction: Instruction) -> Int {
        code.instructions.append(instruction)
        return code.instructions.count - 1
    }

    private var here: Int { code.instructions.count }

    /// Makes the jump at `index` land on `target`.
    private mutating func patch(_ index: Int, to target: Int) {
        let offset = Int32(target - (index + 1))
        switch code.instructions[index] {
        case .jump: code.instructions[index] = .jump(offset: offset)
        case .jumpIfFalse(let condition, _):
            code.instructions[index] = .jumpIfFalse(condition: condition, offset: offset)
        case .jumpIfTrue(let condition, _):
            code.instructions[index] = .jumpIfTrue(condition: condition, offset: offset)
        case .shortCircuit(let op, let register, _):
            code.instructions[index] = .shortCircuit(op: op, register: register, offset: offset)
        case .jumpIfNotNil(let register, _):
            code.instructions[index] = .jumpIfNotNil(register: register, offset: offset)
        case .rangeNext(let counter, let variable, _):
            code.instructions[index] = .rangeNext(
                counter: counter,
                variable: variable,
                exit: offset
            )
        default: preconditionFailure("not a jump")
        }
    }

    private mutating func jump(to target: Int) {
        let index = emit(.jump(offset: 0))
        patch(index, to: target)
    }

    private mutating func allocate() throws -> Register {
        guard nextTemporary < Int(Register.max) - 1 else { throw Unsupported("too many registers") }
        defer { nextTemporary += 1 }
        highest = max(highest, nextTemporary)
        return Register(nextTemporary)
    }

    private mutating func constant(_ value: Value) -> UInt32 {
        code.constants.append(value)
        return UInt32(code.constants.count - 1)
    }

    private mutating func range(of program: Program, _ index: Int) -> Int32 {
        code.ranges.append(index < program.ranges.count ? program.ranges[index] : nil)
        return Int32(code.ranges.count - 1)
    }
}

extension CodeCompiler {
    // MARK: Statements

    private mutating func statements(of program: Program) throws {
        for (index, statement) in program.statements.enumerated() {
            let range = range(of: program, index)
            try compile(statement, range: range)
        }
    }

    /// A block: a scope of its own, whose locals are cleared when it ends.
    private mutating func block(
        _ program: Program,
        entering names: [String: (slot: Register, mutable: Bool)] = [:],
        clearing: Bool = true
    ) throws {
        guard let locals = program.locals else { throw Unsupported("a block run by name") }
        var scope = Scope()
        for (name, local) in names {
            scope.locals[name] = Local(slot: local.slot, mutable: local.mutable)
        }
        if let first = locals.map(\.slot).min(), let last = locals.map(\.slot).max() {
            scope.cleared = (Register(first), Register(last - first + 1))
        }
        scopes.append(scope)
        try statements(of: program)
        if clearing, let cleared = scope.cleared {
            emit(.clear(first: cleared.first, count: cleared.count))
        }
        scopes.removeLast()
    }

    private mutating func compile(_ statement: Statement, range: Int32) throws {
        // What the tree evaluator counts: every statement but a declaration, which it does first.
        switch statement {
        case .function, .enumDecl, .structDecl, .classDecl, .protocolDecl, .typeExtension,
            .extensionDecl, .operatorDeclaration, .deferBlock:
            throw Unsupported("a declaration in a body")
        default:
            emit(.step(range: range))
        }
        switch statement {
        case .declareLocal(let local, let mutable, let value):
            let slot = Register(local.slot)
            try expression(value, into: slot)
            scopes[scopes.count - 1].locals[local.name] = Local(slot: slot, mutable: mutable)
            finished(statement)
        case .assign(let assignment):
            try assign(assignment)
            finished(statement)
        case .expression(let value):
            let mark = nextTemporary
            let result = try allocate()
            try expression(value, into: result)
            emit(.finished(statement: stored(statement), value: result))
            nextTemporary = mark
        case .returnStatement(let value):
            if let value {
                let mark = nextTemporary
                emit(.returnValue(try operand(value)))
                nextTemporary = mark
            } else {
                emit(.returnNothing)
            }
        case .ifStatement(let node):
            try ifStatement(node, statement)
        case .whileLoop(let loop):
            try whileLoop(loop, statement, range: range)
        case .forLoop(let loop):
            try forLoop(loop, statement)
        case .breakStatement(let label):
            try leave(label, isBreak: true)
        case .continueStatement(let label):
            try leave(label, isBreak: false)
        default:
            throw Unsupported("a statement the VM does not run yet")
        }
    }

    private mutating func stored(_ statement: Statement) -> UInt32 {
        code.statements.append(statement)
        return UInt32(code.statements.count - 1)
    }

    /// Tells the host a statement without a value finished.
    private mutating func finished(_ statement: Statement) {
        emit(.finished(statement: stored(statement), value: Register.max))
    }

    private mutating func assign(_ assignment: Assignment) throws {
        guard assignment.path.isEmpty, let local = lookup(assignment.root), local.mutable else {
            throw Unsupported("an assignment to something but a local variable")
        }
        let mark = nextTemporary
        let value = try allocate()
        try expression(assignment.value, into: value)
        emit(.assign(local: local.slot, op: assignment.op, value: value))
        nextTemporary = mark
    }

    private mutating func ifStatement(_ node: IfStatement, _ statement: Statement) throws {
        guard case .expression(let condition) = node.condition else {
            throw Unsupported("an if with a binding or a pattern")
        }
        finished(statement)
        let mark = nextTemporary
        let test = try operand(condition)
        let skip = emit(.jumpIfFalse(condition: test, offset: 0))
        nextTemporary = mark
        try block(node.then)
        if let otherwise = node.otherwise {
            let over = emit(.jump(offset: 0))
            patch(skip, to: here)
            try block(otherwise)
            patch(over, to: here)
        } else {
            patch(skip, to: here)
        }
    }

    private mutating func whileLoop(_ loop: WhileLoop, _ statement: Statement, range: Int32) throws
    {
        finished(statement)
        if loop.isRepeat {
            let head = here
            loops.append(Loop(label: loop.label, scopeDepth: scopes.count))
            emit(.tick)
            try block(loop.body)
            let context = loops.removeLast()
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
        let test = try operand(loop.condition)
        let exit = emit(.jumpIfFalse(condition: test, offset: 0))
        nextTemporary = mark
        loops.append(Loop(label: loop.label, scopeDepth: scopes.count, continueTarget: head))
        emit(.tick)
        try block(loop.body)
        jump(to: head)
        let context = loops.removeLast()
        patch(exit, to: here)
        for index in context.breaks { patch(index, to: here) }
    }

    private mutating func forLoop(_ loop: ForLoop, _ statement: Statement) throws {
        guard !loop.isAwait, !loop.isTry,
            case .binary(let op, let lower, let upper) = loop.sequence,
            op == .closedRange || op == .halfOpenRange
        else { throw Unsupported("a for over something but a range") }
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
        loops.append(Loop(label: loop.label, scopeDepth: scopes.count, continueTarget: head))
        emit(.tick)
        try block(loop.body, entering: entering)
        jump(to: head)
        let context = loops.removeLast()
        patch(next, to: here)
        for index in context.breaks { patch(index, to: here) }
        nextTemporary = mark
    }

    /// `break` and `continue`: the blocks left clear their locals first, as ending a block does.
    private mutating func leave(_ label: String?, isBreak: Bool) throws {
        guard let index = loops.lastIndex(where: { label == nil || $0.label == label }) else {
            throw Unsupported("a break or continue outside a loop")
        }
        for scope in scopes[loops[index].scopeDepth...].reversed() {
            if let cleared = scope.cleared {
                emit(.clear(first: cleared.first, count: cleared.count))
            }
        }
        if isBreak {
            loops[index].breaks.append(emit(.jump(offset: 0)))
        } else if let target = loops[index].continueTarget {
            jump(to: target)
        } else {
            loops[index].continues.append(emit(.jump(offset: 0)))
        }
    }

    private func lookup(_ name: String) -> Local? {
        for scope in scopes.reversed() {
            if let local = scope.locals[name] { return local }
        }
        return nil
    }
}

extension CodeCompiler {
    // MARK: Expressions

    /// The register an expression's value is in: a local's own, or a temporary it was computed into.
    private mutating func operand(_ expression: Expr) throws -> Register {
        if case .local(let local) = expression { return Register(local.slot) }
        let result = try allocate()
        try self.expression(expression, into: result)
        return result
    }

    private mutating func expression(_ expression: Expr, into destination: Register) throws {
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
            code.names.append(name)
            emit(.loadVariable(dst: destination, name: UInt32(code.names.count - 1)))
        case .binary(let op, let lhs, let rhs):
            try binary(op, lhs, rhs, into: destination)
        case .unary(let op, let operand):
            let source = try self.operand(operand)
            emit(.unary(op: op, dst: destination, src: source))
        case .annotated(let inner, let type):
            try self.expression(inner, into: destination)
            code.types.append(type)
            emit(.conform(dst: destination, src: destination, type: UInt32(code.types.count - 1)))
        case .call(let callee, let arguments):
            try call(callee, arguments, into: destination)
        default:
            throw Unsupported("an expression the VM does not run yet")
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
    )
        throws
    {
        var named = callee
        if case .chosen(let inner, _) = callee { named = inner }
        guard case .variable(let name) = named else {
            throw Unsupported("a call of something but a name")
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
