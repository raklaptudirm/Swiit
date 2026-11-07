/// The locals of one run of a function, a closure or a program: a slot for each local, which the
/// variable in it is put in when it is bound and taken out of when its block ends. A slot is
/// given once for each place a local is declared (`FrameResolver`), and blocks side by side share
/// them, so a frame is as big as the most locals alive at once.
///
/// A local is still found by its name: the frame is asked before the scopes made before it, and
/// after those made since (the bindings of an `if` expression, a `case`'s `where`). Of two locals of
/// one name, the later slot is the inner one, which shadows the other.
final class Frame {
    private var slots: ContiguousArray<(name: String, binding: Binding)?>

    init(size: Int) {
        slots = ContiguousArray(repeating: nil, count: size)
    }

    func bind(_ name: String, _ binding: Binding, at slot: Int) {
        slots[slot] = (name, binding)
    }

    /// The block whose locals these are has ended.
    func clear(_ locals: [Program.Local]) {
        for local in locals { slots[local.slot] = nil }
    }

    /// The innermost local of that name alive now.
    func binding(named name: String) -> Binding? {
        var index = slots.count - 1
        while index >= 0 {
            if let local = slots[index], local.name == name { return local.binding }
            index -= 1
        }
        return nil
    }
}

/// Gives each local of a function, a closure or a program the slot of its frame it lives in: the
/// `let` and `var` of a block, and the names a block begins with (a `for`'s, an `if let`'s, a
/// `case`'s and a `catch`'s). What it cannot place leaves the whole body as it was, to be run by
/// name: a `guard let`, which binds into the block it is in, and a function or type declared
/// inside a block, which are bound by name where they are.
///
/// The program's own `let` and `var` are globals, which stay by name: the host and later runs read
/// them so. Each function or closure is a frame of its own.
struct FrameResolver {
    private var next = 0
    private var size = 0
    private var placeable = true

    /// The program, with the locals of its blocks and of the functions and closures in it given
    /// slots.
    static func resolve(program: Program) -> Program {
        resolve(body: program, isProgram: true)
    }

    private static func resolve(body: Program, isProgram: Bool) -> Program {
        var resolver = FrameResolver()
        var resolved = resolver.block(body, entering: [], isProgram: isProgram)
        guard resolver.placeable else { return body }
        resolved.frameSize = resolver.size
        return resolved
    }

    private mutating func slot() -> Int {
        defer {
            next += 1
            size = max(size, next)
        }
        return next
    }

    private mutating func block(
        _ program: Program,
        entering names: [String],
        isProgram: Bool = false
    ) -> Program {
        let start = next
        var locals = names.filter { $0 != "_" }.map { Program.Local(name: $0, slot: slot()) }
        var resolved = program
        resolved.statements = program.statements.map {
            statement($0, isProgram: isProgram, locals: &locals)
        }
        next = start
        if !isProgram { resolved.locals = locals }
        return resolved
    }

    private mutating func statement(
        _ statement: Statement,
        isProgram: Bool,
        locals: inout [Program.Local]
    ) -> Statement {
        switch statement {
        case .declare(let name, let mutable, let value):
            let value = expression(value)
            if isProgram || name == "_" {
                return .declare(name: name, mutable: mutable, value: value)
            }
            let local = Program.Local(name: name, slot: slot())
            locals.append(local)
            return .declareLocal(local, mutable: mutable, value: value)
        case .function(var decl):
            guard isProgram else {
                placeable = false
                return statement
            }
            decl.body = FrameResolver.resolve(body: decl.body, isProgram: false)
            return .function(decl)
        case .enumDecl, .structDecl, .classDecl, .protocolDecl, .typeExtension, .extensionDecl,
            .operatorDeclaration:
            if !isProgram { placeable = false }
            return statement
        case .guardStatement:
            placeable = false
            return statement
        case .ifStatement(let node):
            return .ifStatement(ifStatement(node))
        case .forLoop(var loop):
            loop.sequence = expression(loop.sequence)
            loop.body = block(loop.body, entering: FrameResolver.names(in: loop.pattern))
            return .forLoop(loop)
        case .whileLoop(var loop):
            loop.condition = expression(loop.condition)
            loop.body = block(loop.body, entering: [])
            return .whileLoop(loop)
        case .switchStatement(var node):
            node.subject = expression(node.subject)
            node.cases = node.cases.map { switchCase($0) }
            return .switchStatement(node)
        case .doCatch(let body, let clauses):
            return .doCatch(
                body: block(body, entering: []),
                clauses: clauses.map { clause in
                    var resolved = clause
                    // A `catch` without a pattern has the error as `error`.
                    let names =
                        clause.patterns.isEmpty
                        ? ["error"] : clause.patterns.flatMap(FrameResolver.names(in:))
                    resolved.body = block(clause.body, entering: Array(Set(names)))
                    return resolved
                }
            )
        case .deferBlock(let body):
            return .deferBlock(block(body, entering: []))
        case .expression(let value):
            return .expression(expression(value))
        case .returnStatement(let value):
            return .returnStatement(value.map { expression($0) })
        case .throwStatement(let value):
            return .throwStatement(expression(value))
        case .assign, .declareLocal, .fallthroughStatement, .breakStatement, .continueStatement:
            return statement
        }
    }

    private mutating func ifStatement(_ node: IfStatement) -> IfStatement {
        var resolved = node
        let names: [String]
        switch node.condition {
        case .expression(let value):
            resolved.condition = .expression(expression(value))
            names = []
        case .binding(let name, let mutable, let value):
            resolved.condition = .binding(name: name, mutable: mutable, value: expression(value))
            names = [name]
        case .pattern(let pattern, let value):
            resolved.condition = .pattern(pattern, expression(value))
            names = FrameResolver.names(in: pattern)
        }
        resolved.then = block(node.then, entering: names)
        if let otherwise = node.otherwise {
            // An `else if` is an `if` statement alone in the `else`.
            resolved.otherwise = block(otherwise, entering: [])
        }
        return resolved
    }

    private mutating func switchCase(_ node: SwitchCase) -> SwitchCase {
        var resolved = node
        // Every pattern of a case binds the same names.
        let names = Set(node.patterns.flatMap(FrameResolver.names(in:)))
        resolved.body = block(node.body, entering: Array(names))
        return resolved
    }

    /// The closures in an expression, each with its own frame. What is not looked into keeps its
    /// closures as they were, to be run by name.
    private func expression(_ value: Expr) -> Expr {
        switch value {
        case .closure(var literal):
            literal.body = FrameResolver.resolve(body: literal.body, isProgram: false)
            return .closure(literal)
        case .call(let callee, let arguments):
            return .call(expression(callee), arguments.map(argument))
        case .chosen(let inner, let overload):
            return .chosen(expression(inner), overload: overload)
        case .specialized(let inner, let types):
            return .specialized(expression(inner), types)
        case .member(let base, let name):
            return .member(expression(base), name)
        case .bridged(let type, let member, let receiver, let arguments):
            return .bridged(
                type: type,
                member: member,
                receiver: receiver.map(expression),
                arguments: arguments.map(argument)
            )
        case .attempt(let inner, let kind):
            return .attempt(expression(inner), kind)
        case .await(let inner, let throwing):
            return .await(expression(inner), throwing: throwing)
        case .annotated(let inner, let type):
            return .annotated(expression(inner), type)
        case .binary(let op, let left, let right):
            return .binary(op, expression(left), expression(right))
        case .unary(let op, let operand):
            return .unary(op, expression(operand))
        case .list(let items):
            return .list(items.map(expression))
        case .tuple(let arguments):
            return .tuple(arguments.map(argument))
        default:
            return value
        }
    }

    private func argument(_ argument: Argument) -> Argument {
        Argument(label: argument.label, value: expression(argument.value))
    }

    /// The names a pattern binds.
    static func names(in pattern: Pattern) -> [String] {
        switch pattern {
        case .binding(let name, _): [name]
        case .enumCase(_, _, let arguments): (arguments ?? []).flatMap { names(in: $0.pattern) }
        case .cast(let inner, _), .some(let inner): names(in: inner)
        case .tuple(let patterns): patterns.flatMap(names(in:))
        case .wildcard, .expression, .isType, .partialRange: []
        }
    }
}
