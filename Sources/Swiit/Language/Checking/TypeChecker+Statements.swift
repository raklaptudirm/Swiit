import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Statements

    @_spi(Shell) public func checkBlock(_ program: inout Program, declaring names: [String: Symbol] = [:], newScope: Bool = false) throws {
        if newScope { scopes.append(names) }
        defer { if newScope { scopes.removeLast() } }
        // Declared first, so functions and types can be used before (and by)
        // their declarations, as in Swift.
        for statement in program.statements {
            switch statement {
            case .function(let decl): declareFunction(decl)
            case .structDecl(let decl): scopes[scopes.count - 1][decl.name] = .structType(try structInfo(decl))
            case .enumDecl(let decl): scopes[scopes.count - 1][decl.name] = .enumType(enumInfo(decl))
            default: break
            }
        }
        for index in program.statements.indices {
            if index < program.lines.count { line = program.lines[index] }
            try checkStatement(&program.statements[index])
        }
    }

    @_spi(Shell) public func checkStatement(_ statement: inout Statement) throws {
        switch statement {
        case .declare(let name, let mutable, var value):
            var type = try typeOf(&value)
            if type == .optional(.unknown), case .literal(.nothing) = value {
                throw TypeError("'nil' needs a type: let \(name): T? = nil")
            }
            if case .tuple([]) = type { type = .void }
            scopes[scopes.count - 1][name] = .variable(type, mutable: mutable)
            statement = .declare(name: name, mutable: mutable, value: value)
        case .assign(var assignment):
            try checkAssignment(&assignment)
            statement = .assign(assignment)
        case .function(var decl):
            try checkFunction(&decl)
            statement = .function(decl)
        case .extended(var box):
            try box.node.check(in: self)
            statement = .extended(box)
        case .doCatch(var body, let errorName, var handler):
            // A `do` with a `catch` handles what its body throws.
            errorContexts.append(ErrorContext(handled: handler != nil || errorContexts.last!.handled,
                                              boundary: errorContexts.last!.boundary))
            try checkBlock(&body, newScope: true)
            errorContexts.removeLast()
            if var caught = handler {
                try checkBlock(&caught, declaring: [errorName: .variable(.named("Error"), mutable: false)], newScope: true)
                handler = caught
            }
            statement = .doCatch(body: body, errorName: errorName, handler: handler)
        case .enumDecl(var decl):
            try checkEnum(&decl)
            statement = .enumDecl(decl)
        case .structDecl(var decl):
            try checkStruct(&decl)
            statement = .structDecl(decl)
        case .guardStatement(let condition, var otherwise):
            var node = IfStatement(condition: condition, then: Program(statements: []))
            let bound = try checkCondition(&node)
            try checkBlock(&otherwise, newScope: true)
            guard definitelyLeaves(otherwise, orExits: true) else {
                throw TypeError("guard's else must not carry on: end it with return, break, continue or exit")
            }
            // What the condition binds is bound for the rest of the block.
            for (name, symbol) in bound { scopes[scopes.count - 1][name] = symbol }
            statement = .guardStatement(node.condition, otherwise: otherwise)
        case .returnStatement(var value):
            guard let context = returns.last else { return }
            if value != nil {
                if context.declared == .void {
                    throw TypeError("a function without '->' returns nothing, so 'return' takes no value")
                }
                if let declared = context.declared {
                    try expect(&value!, declared, "the returned value")
                } else {
                    context.seen.append(try typeOf(&value!))
                }
            } else if let declared = context.declared, declared != .void, declared != .unknown {
                throw TypeError("this function must return \(declared)")
            }
            statement = .returnStatement(value)
        case .fallthroughStatement, .breakStatement, .continueStatement, .extensionDecl:
            break
        case .deferBlock(var body):
            // Nothing thrown can leave a `defer`, as in Swift.
            errorContexts.append(ErrorContext(handled: false, boundary: .deferBlock))
            try checkBlock(&body, newScope: true)
            errorContexts.removeLast()
            statement = .deferBlock(body)
        case .chain(var chain):
            try checkChain(&chain, condition: false)
            statement = .chain(chain)
        }
    }

    @_spi(Shell) public func checkChain(_ chain: inout Chain, condition: Bool) throws {
        try checkUnit(&chain.first, condition: condition || !chain.links.isEmpty)
        for index in chain.links.indices { try checkUnit(&chain.links[index].unit, condition: true) }
    }

    /// `condition`: the unit's status decides something, as in `if` or
    /// `&&`: an expression there must be a Bool, an Output, or optional.
    @_spi(Shell) public func checkUnit(_ unit: inout Unit, condition: Bool) throws {
        switch unit {
        case .extended(var box):
            try box.node.check(in: self)
            unit = .extended(box)
        case .expression(var expr):
            let type = try typeOf(&expr)
            if condition {
                // `if try? build()`: whether it succeeded.
                let attempted = if case .attempt(_, .optional) = expr { true } else { false }
                switch type {
                case .bool, .output, .unknown: break
                case .optional where attempted: break
                default: throw TypeError("a condition must be a Bool, not \(type)")
                }
            }
            unit = .expression(expr)
        case .ifStatement(var node):
            try checkIf(&node)
            unit = .ifStatement(node)
        case .switchStatement(var node):
            try checkSwitch(&node)
            unit = .switchStatement(node)
        case .forLoop(var loop):
            let element = try elementType(of: try typeOf(&loop.sequence))
            try checkBlock(&loop.body, declaring: [loop.variable: .variable(element, mutable: false)], newScope: true)
            unit = .forLoop(loop)
        case .whileLoop(var loop):
            try checkChain(&loop.condition, condition: true)
            try checkBlock(&loop.body, newScope: true)
            unit = .whileLoop(loop)
        }
    }

    @_spi(Shell) public func checkIf(_ node: inout IfStatement) throws {
        let bound = try checkCondition(&node)
        try checkBlock(&node.then, declaring: bound, newScope: true)
        if var otherwise = node.otherwise {
            try checkBlock(&otherwise, newScope: true)
            node.otherwise = otherwise
        }
    }

    /// An `if` expression's type: what both branches are, as for a list's
    /// elements, so `c ? 1 : nil` is an Int?.
    @_spi(Shell) public func ifExpressionType(_ node: inout IfStatement, expected: TypeAnnotation?) throws -> TypeAnnotation {
        let bound = try checkCondition(&node)
        guard var thenExpr = IfStatement.branchExpression(node.then),
              var elseExpr = IfStatement.branchExpression(node.otherwise ?? Program(statements: [])) else {
            throw TypeError("each branch of an if expression must be one expression")
        }
        scopes.append(bound)
        let thenNil = thenExpr == .literal(.nothing)
        let elseNil = elseExpr == .literal(.nothing)
        var thenType = thenNil ? nil : try typeOf(&thenExpr, expecting: expected)
        scopes.removeLast()
        let elseType = try typeOf(&elseExpr, expecting: expected ?? thenType.map { elseNil ? .optional($0) : $0 })
        if thenNil { thenType = try typeOf(&thenExpr, expecting: expected ?? .optional(elseType)) }
        node.then = IfStatement.branch(thenExpr)
        node.otherwise = IfStatement.branch(elseExpr)
        guard let type = commonType([thenType!, elseType]) else {
            throw TypeError("an if expression's branches must have one type, not \(thenType!) and \(elseType)")
        }
        return type
    }

    /// Checks an `if`'s condition, giving what it binds for the `then` branch.
    @_spi(Shell) public func checkCondition(_ node: inout IfStatement) throws -> [String: Symbol] {
        var bound: [String: Symbol] = [:]
        switch node.condition {
        case .chain(var chain):
            try checkChain(&chain, condition: true)
            node.condition = .chain(chain)
        case .binding(let name, let mutable, var value):
            let type = try typeOf(&value)
            if case .optional(let wrapped) = type {
                bound[name] = .variable(wrapped, mutable: mutable)
            } else if type == .unknown {
                bound[name] = .variable(.unknown, mutable: mutable)
            } else {
                throw TypeError("'let' in a condition unwraps an optional, but this is \(type)")
            }
            node.condition = .binding(name: name, mutable: mutable, value: value)
        case .pattern(var pattern, var value):
            try checkPattern(&pattern, against: try typeOf(&value), binding: &bound)
            node.condition = .pattern(pattern, value)
        }
        return bound
    }

    @_spi(Shell) public func checkSwitch(_ node: inout SwitchStatement) throws {
        let subject = try typeOf(&node.subject)
        for index in node.cases.indices {
            var bound: [String: Symbol] = [:]
            for patternIndex in node.cases[index].patterns.indices {
                try checkPattern(&node.cases[index].patterns[patternIndex], against: subject, binding: &bound)
            }
            scopes.append(bound)
            defer { scopes.removeLast() }
            if node.cases[index].guardExpr != nil {
                try expect(&node.cases[index].guardExpr!, .bool, "a case's 'where'")
            }
            try checkBlock(&node.cases[index].body, newScope: true)
        }
    }

    @_spi(Shell) public func checkPattern(_ pattern: inout Pattern, against type: TypeAnnotation, binding bound: inout [String: Symbol]) throws {
        switch pattern {
        case .wildcard:
            break
        case .binding(let name, let mutable):
            bound[name] = .variable(type, mutable: mutable)
        case .enumCase(let typeName, let name, var arguments):
            var subject = type
            if case .optional(let wrapped) = subject { subject = wrapped }
            if subject == .unknown {
                for index in (arguments ?? []).indices {
                    try checkPattern(&arguments![index].pattern, against: .unknown, binding: &bound)
                }
                pattern = .enumCase(type: typeName, name: name, arguments: arguments)
                return
            }
            guard case .named(let enumName) = subject, let info = enumInfo(named: enumName) else {
                throw TypeError("a case pattern like .\(name) matches an enum, not \(type)")
            }
            if let typeName, typeName != enumName {
                throw TypeError("\(typeName).\(name) can't match a \(enumName)")
            }
            guard let payload = info.payload(of: name) else { throw TypeError("\(enumName) has no case '\(name)'") }
            guard arguments != nil else { return }
            guard arguments!.count == payload.count else {
                throw TypeError("\(enumName).\(name) has \(payload.count) associated values, not \(arguments!.count)")
            }
            for index in arguments!.indices {
                try checkPattern(&arguments![index].pattern, against: payload[index].type, binding: &bound)
            }
            pattern = .enumCase(type: typeName, name: name, arguments: arguments)
        case .expression(var expr):
            if case .binary(let op, var lower, var upper) = expr, op == .closedRange || op == .halfOpenRange {
                let boundType = type == .double ? TypeAnnotation.double : type
                try expect(&lower, boundType, "a range's bound")
                try expect(&upper, boundType, "a range's bound")
                pattern = .expression(.binary(op, lower, upper))
                return
            }
            let valueType = try typeOf(&expr, expecting: type)
            guard fits(valueType, type) || fits(type, valueType) else {
                throw TypeError("a \(valueType) can't match a \(type)")
            }
            pattern = .expression(expr)
        }
    }
}

extension TypeChecker {
    // MARK: Throwing

    /// A plain `try` covers something that throws: it has to be handled.
    @_spi(Shell) public func checkHandled(_ what: String) throws {
        guard let context = errorContexts.last, !context.handled else { return }
        throw TypeError("\(what) can throw, but \(context.boundary.unhandled)")
    }

    /// Something that can throw, like a call to a `throws` function: it
    /// needs a `try` covering it.
    @_spi(Shell) public func throwingSite(_ what: String) throws {
        throwingSites += 1
        guard tryDepth > 0 else {
            throw TypeError("\(what) can throw, but isn't marked with 'try'")
        }
    }
}
