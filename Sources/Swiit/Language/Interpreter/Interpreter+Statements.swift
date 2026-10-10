import Foundation
import SwishKit

extension Interpreter {
    // MARK: Statements

    /// Runs a program. A host that shows what a program gives, as the shell
    /// does at the prompt and in scripts, passes an `observer`: it is told the
    /// value of each of the program's own expression statements. Statements
    /// nested in blocks, like the body of a `for`, aren't the program's own,
    /// as in Swift's REPL: use `print` for those.
    @_spi(Shell) public func run(_ program: Program, observing observer: ValueObserver? = nil) throws {
        try hoistDeclarations(program)
        // `defer` blocks run as the block ends, however it ends.
        var deferred: [Program] = []
        defer { runDeferred(deferred) }
        for statement in program.statements {
            if case .deferBlock(let body) = statement {
                deferred.append(body)
                continue
            }
            if statement.declaresType { continue } // Hoisted.
            try checkInterrupt()
            if let observer, case .expression(let expression) = statement {
                try runObserved(expression, observer)
            } else {
                try run(statement)
            }
        }
    }

    /// The branch of an `if` its condition picks, with what the condition
    /// binds; nil for no `else`.
    @_spi(Shell) public func chooseBranch(_ node: IfStatement) throws -> (Program?, [String: Binding]) {
        if let bindings = try holds(node.condition) { return (node.then, bindings) }
        return (node.otherwise, [:])
    }

    /// What an `if` or `guard` condition binds when it holds; nil when it doesn't.
    @_spi(Shell) public func holds(_ condition: IfStatement.Condition) throws -> [String: Binding]? {
        switch condition {
        case .pattern(let pattern, let expr):
            var bindings: [String: Binding] = [:]
            return try match(pattern, try evaluate(expr), into: &bindings) ? bindings : nil
        case .expression(let expr):
            return try isTrue(expr) ? [:] : nil
        case .binding(let name, let mutable, let expr):
            let value = try evaluate(expr)
            return value != .nothing ? [name: Binding(value: value, mutable: mutable)] : nil
        }
    }

    /// A condition's value.
    @_spi(Shell) public func isTrue(_ condition: Expr) throws -> Bool {
        let value = try evaluate(condition)
        guard case .bool(let truth) = value else { throw RuntimeError("condition must be a Bool, not \(value.typeName)") }
        return truth
    }

    /// Declares a block's functions and types before it runs, so they can
    /// be used before their declarations, as in Swift. A function is
    /// declared again where it's written, which captures what's been
    /// declared by then, as it always has.
    @_spi(Shell) public func hoistDeclarations(_ program: Program) throws {
        for statement in program.statements {
            if case .function = statement { try run(statement) }
            else if statement.declaresType { try run(statement) }
        }
    }

    /// Deferred blocks, last first. One that fails is reported; the rest
    /// still run, as nothing can leave a `defer`.
    @_spi(Shell) public func runDeferred(_ blocks: [Program]) {
        let status = lastStatus
        for body in blocks.reversed() {
            do {
                try runBlock(body)
            } catch let error as RuntimeError {
                report("error: \(error)")
            } catch {
                report("error: \(error)")
            }
        }
        lastStatus = status
    }

    @_spi(Shell) public func runBlock(_ program: Program, declaring bindings: [String: Binding] = [:]) throws {
        scopes.append(Scope(bindings))
        defer { scopes.removeLast() }
        try run(program)
    }

    @_spi(Shell) public func run(_ statement: Statement) throws {
        let errorsBefore = itemErrorCount
        switch statement {
        case .extensionDecl, .deferBlock:
            // The prelude's, read at startup; collected by the block that holds it.
            return
        case .declare(let name, let mutable, let expr):
            let value = try evaluate(expr)
            scopes[scopes.count - 1].bindings[name] = Binding(value: value, mutable: mutable)
        case .assign(let assignment):
            try assign(assignment)
        case .structDecl(let decl):
            try declare(decl)
        case .function(let decl):
            // Captures the scope it's bound in, so it can call itself.
            let function = Function(
                name: decl.name, parameters: decl.parameters, returnType: decl.returnType,
                body: .swish(decl.body), captured: captureScopes(decl.names), documentation: decl.documentation,
                isThrowing: decl.isThrowing
            )
            scopes[scopes.count - 1].declare(function, named: decl.name)
        case .extended:
            throw RuntimeError.unrewritten
        case .enumDecl(let decl):
            try declare(decl)
        case .expression(let expr):
            let value = try evaluate(expr)
            statementFinished?(statement, value, itemErrorCount > errorsBefore)
            return
        // What runs inside these says how they went, and a body that doesn't
        // run leaves them as a statement that did nothing.
        case .doCatch(let body, let errorName, let handler):
            statementFinished?(statement, nil, false)
            do {
                try runBlock(body)
            } catch let error as RuntimeError {
                guard let handler else { throw error }
                try runBlock(handler, declaring: [errorName: Binding(value: error.value, mutable: false)])
            } catch let reported as AlreadyReported {
                guard let handler else { throw reported }
                try runBlock(handler, declaring: [errorName: Binding(value: reported.error.value, mutable: false)])
            }
            return
        case .ifStatement(let node):
            statementFinished?(statement, nil, false)
            let (branch, bindings) = try chooseBranch(node)
            if let branch { try runBlock(branch, declaring: bindings) }
            return
        case .switchStatement(let node):
            statementFinished?(statement, nil, false)
            try runSwitch(node)
            return
        case .forLoop(let loop):
            statementFinished?(statement, nil, false)
            try forEachElement(of: loop.sequence) { element in
                let bindings = loop.variable == "_" ? [:] : [loop.variable: Binding(value: element, mutable: false)]
                return try runLoopBody(loop.body, declaring: bindings)
            }
            return
        case .whileLoop(let loop):
            statementFinished?(statement, nil, false)
            while try isTrue(loop.condition) {
                guard try runLoopBody(loop.body, declaring: [:]) else { break }
            }
            return
        case .fallthroughStatement:
            throw ControlFlow.fallthroughCase
        case .guardStatement(let condition, let otherwise):
            if let bindings = try holds(condition) {
                for (name, binding) in bindings { scopes[scopes.count - 1].bindings[name] = binding }
                return
            }
            try runBlock(otherwise)
            // The checker sees to it that the else leaves; `exit` might not
            // (with jobs left, it only warns).
            throw RuntimeError("guard's else carried on")
        case .returnStatement(let expr):
            // A `.case` returned from a function declared to return an enum.
            throw ControlFlow.returned(try expr.map { try evaluate($0, expecting: returnTypes.last ?? nil) } ?? .nothing)
        case .breakStatement:
            throw ControlFlow.breakLoop
        case .continueStatement:
            throw ControlFlow.continueLoop
        }
        statementFinished?(statement, nil, itemErrorCount > errorsBefore)
    }

    /// An expression statement at the top level: evaluated, and shown to the
    /// observer (unless it is a bare `true` or `false`, which stand in for the
    /// Unix commands).
    @_spi(Shell) public func runObserved(_ expr: Expr, _ observer: ValueObserver) throws {
        let errorsBefore = itemErrorCount
        let value = try evaluate(expr)
        let isBoolLiteral = if case .literal(.bool) = expr { true } else { false }
        // `xs.removeLast()` alone: Swift's @discardableResult.
        let discarded = if case .bridged(let type, let member, _, _) = expr {
            Bridge.types[type]?.members[member].discardableResult == true
        } else { false }
        if !isBoolLiteral { try observer(value, expr, discarded) }
        statementFinished?(.expression(expr), value, itemErrorCount > errorsBefore)
    }

    /// Runs one iteration; false means `break`.
    @_spi(Shell) public func runLoopBody(_ body: Program, declaring bindings: [String: Binding]) throws -> Bool {
        try checkInterrupt()
        do {
            try runBlock(body, declaring: bindings)
        } catch ControlFlow.breakLoop {
            return false
        } catch ControlFlow.continueLoop {}
        return true
    }

    /// Iterates lists, ranges lazily (so `for i in 1...1_000_000_000` never
    /// builds a list), strings by character, as in Swift, the Swift
    /// sequences Swish holds, and command output by line.
    @_spi(Shell) public func forEachElement(of sequence: Expr, _ body: (Value) throws -> Bool) throws {
        if case .binary(let op, let lower, let upper) = sequence, op == .closedRange || op == .halfOpenRange {
            for i in try intRange(op, try evaluate(lower), try evaluate(upper)) {
                guard try body(.int(i)) else { return }
            }
            return
        }
        let value = try evaluate(sequence)
        if let flow = Interpreter.flow(of: value) {
            while let element = try flow.read() {
                guard try body(element) else { return }
            }
            return
        }
        let elements: AnyIterator<Value>
        if case .string(let text) = value {
            elements = AnyIterator(text.lazy.map { .string(String($0)) }.makeIterator())
        } else if let items = Interpreter.items(of: value) {
            elements = items
        } else {
            throw RuntimeError("can't iterate over \(value.typeName)")
        }
        for element in elements {
            guard try body(element) else { return }
        }
    }

    @_spi(Shell) public func checkInterrupt() throws {
        if cancellation.isSet { throw Cancelled() }
        if let reason = host.interrupt() { throw Interrupted(reason: reason) }
        steps += 1
        if let maximum = limits.steps, steps > maximum { throw LimitExceeded("step limit (\(maximum)) exceeded") }
        if let deadline, ContinuousClock.now > deadline { throw LimitExceeded("time limit exceeded") }
        if let maximum = limits.output, outputCounter.written > maximum {
            throw LimitExceeded("output limit (\(maximum) bytes) exceeded")
        }
    }
}

/// Told the value of each top-level expression statement: the value, the
/// expression it came from, and whether Swift would discard it
/// (`@discardableResult`).
/// Told each simple statement as it finishes: the statement, an expression
/// statement's value, and whether a per-item error was reported while it ran.
/// An `if`, a loop, a `switch` and a `do` are told as they start, with no
/// value; the statements in them are told as they run. The shell keeps the
/// exit status from these.
@_spi(Shell) public typealias StatementObserver = (_ statement: Statement, _ value: Value?, _ itemErrors: Bool) -> Void

@_spi(Shell) public typealias ValueObserver = (_ value: Value, _ expression: Expr, _ discarded: Bool) throws -> Void
