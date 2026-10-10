import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Declarations

    /// Adds `decl` to its name's overloads, in the order the interpreter
    /// keeps them: one with the same parameters replaces the old.
    @_spi(Shell) public func declareFunction(_ decl: FunctionDecl) {
        var overloads: [Signature] = []
        if case .functions(let existing)? = scopes[scopes.count - 1][decl.name] {
            overloads = existing
        } else if scopes.count == 1, let binding = interpreter.scopes.last?.bindings[decl.name], binding.isFunction,
                  case .function(let set as OverloadSet) = binding.value {
            // At the top, it joins what earlier entries declared.
            overloads = set.candidates.map(signature)
        }
        overloads.removeAll { sameParameters($0.parameters, decl.parameters) }
        overloads.append(Signature(
            name: decl.name, parameters: decl.parameters, returns: decl.returnType ?? .void, isThrowing: decl.isThrowing
        ))
        for index in overloads.indices { overloads[index].index = index }
        scopes[scopes.count - 1][decl.name] = .functions(overloads)
    }

    @_spi(Shell) public func sameParameters(_ a: [Parameter], _ b: [Parameter]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.label == $1.label && $0.type == $1.type && $0.variadic == $1.variadic }
    }

    @_spi(Shell) public func checkFunction(
        _ decl: inout FunctionDecl, self selfType: TypeAnnotation? = nil, mutating: Bool = false, initializing: Bool = false
    ) throws {
        var names: [String: Symbol] = [:]
        for index in decl.parameters.indices {
            let parameter = decl.parameters[index]
            if decl.parameters[index].defaultValue != nil {
                try expect(&decl.parameters[index].defaultValue!, parameter.type, "\(parameter.name)'s default")
            }
            names[parameter.name] = .variable(parameter.variadic ? .list(parameter.type) : parameter.type, mutable: false)
        }
        if let selfType { names["self"] = .variable(selfType, mutable: mutating || initializing) }
        if initializing { names["$initializing"] = .variable(.void, mutable: false) }
        let result = decl.returnType ?? .void
        returns.append(ReturnContext(declared: result))
        errorContexts.append(ErrorContext(handled: decl.isThrowing, boundary: .function(decl.name)))
        scopes.append(names)
        defer {
            returns.removeLast()
            errorContexts.removeLast()
            scopes.removeLast()
        }

        // A body that's one expression is the result, when there's one.
        if result != .void, var expr = implicitReturn(decl.body) {
            try expect(&expr, result, "\(decl.name)'s result")
            decl.body.statements[0] = .expression(expr)
            return
        }
        try checkBlock(&decl.body)
        if result != .void && result != .unknown && !definitelyReturns(decl.body) {
            throw TypeError("\(decl.name) must return \(result) on every path")
        }
    }

    @_spi(Shell) public func implicitReturn(_ body: Program) -> Expr? {
        guard body.statements.count == 1 else { return nil }
        switch body.statements[0] {
        case .expression(let expr): return expr
        // A body that's one `if` with one expression per branch is that
        // `if` as an expression, as in Swift.
        case .ifStatement(let node): return node.asExpression.map(Expr.ifExpression)
        default: return nil
        }
    }

    /// Whether running `program` always ends in a `return`: as simple as
    /// Swift's own check, from the last statement.
    @_spi(Shell) public func definitelyReturns(_ program: Program) -> Bool {
        definitelyLeaves(program, orExits: false)
    }

    /// Whether running `program` always leaves it: by `return`, or, with
    /// `orExits` (for a guard's `else`), by `break`, `continue` or `exit`.
    @_spi(Shell) public func definitelyLeaves(_ program: Program, orExits: Bool) -> Bool {
        // Declarations after the last statement run nothing, as in Swift.
        guard let last = program.statements.last(where: {
            if case .function = $0 { return false }
            return !$0.declaresType
        }) else { return false }
        let leaves = { (program: Program) in self.definitelyLeaves(program, orExits: orExits) }
        switch last {
        case .returnStatement:
            return true
        case .breakStatement, .continueStatement:
            return orExits
        case .doCatch(let body, _, let handler):
            return leaves(body) && handler.map(leaves) ?? true
        case .ifStatement(let node):
            guard let otherwise = node.otherwise else { return false }
            return leaves(node.then) && leaves(otherwise)
        case .switchStatement(let node):
            // A switch always matches (or fails), so every case returning is enough.
            return !node.cases.isEmpty && node.cases.allSatisfy { leaves($0.body) }
        case .expression(.extended(let box)) where orExits:
            return box.node.leavesProgram
        default:
            return false
        }
    }

    @_spi(Shell) public func structInfo(_ decl: StructDecl) throws -> StructInfo {
        var computed: [String: TypeAnnotation] = [:]
        for property in decl.properties where property.getter != nil { computed[property.name] = property.type ?? .unknown }
        var methods: [String: [Signature]] = [:]
        for method in decl.methods {
            var signature = Signature(name: method.name, parameters: method.parameters, returns: method.returnType ?? .void,
                                      isMutating: method.isMutating, isThrowing: method.isThrowing)
            signature.index = methods[method.name]?.count ?? 0
            methods[method.name, default: []].append(signature)
        }
        var stored: [PropertyDecl] = []
        for var property in decl.properties where property.getter == nil {
            // An untyped property takes its default's type.
            if property.type == nil, var defaultValue = property.defaultValue {
                property.type = try typeOf(&defaultValue)
            }
            stored.append(property)
        }
        let memberwise = Signature(
            name: decl.name,
            parameters: stored.filter { $0.mutable || $0.defaultValue == nil }.map {
                Parameter(label: $0.name, name: $0.name, type: $0.type ?? .unknown, defaultValue: $0.defaultValue)
            },
            returns: .named(decl.name)
        )
        let initializers = decl.initializers.enumerated().map { index, initializer in
            Signature(name: "\(decl.name).init", parameters: initializer.parameters, returns: .named(decl.name),
                      isMutating: true, isThrowing: initializer.isThrowing, index: index)
        }
        // An untyped static takes its value's type once the struct is known
        // (`checkStruct`), since the value may use the struct itself.
        var staticMethods: [String: [Signature]] = [:]
        for method in decl.staticMethods {
            var signature = Signature(name: method.name, parameters: method.parameters, returns: method.returnType ?? .void,
                                      isThrowing: method.isThrowing)
            signature.index = staticMethods[method.name]?.count ?? 0
            staticMethods[method.name, default: []].append(signature)
        }
        return StructInfo(name: decl.name, stored: stored, computed: computed, methods: methods,
                          initializers: initializers, memberwise: memberwise, conformances: decl.conformances,
                          staticProperties: decl.staticProperties, staticMethods: staticMethods)
    }

    @_spi(Shell) public func checkStruct(_ decl: inout StructDecl) throws {
        let selfType = TypeAnnotation.named(decl.name)
        // Equatable, Hashable and Encodable come from the fields, which must
        // have them too; Comparable would need a `<` of its own.
        for proto in decl.conformances {
            if proto == "Comparable" { throw TypeError("\(decl.name) can't be Comparable yet: it would need a '<' of its own") }
            // Iterating needs a `makeIterator` of its own, which nothing declared in Swish has yet.
            if proto == "Sequence" { throw TypeError("\(decl.name) can't be a Sequence yet") }
            guard proto != "CustomStringConvertible" else { continue }
            // Tabular isn't made from the fields: it asks for a static member.
            if proto == "Tabular" {
                guard let columns = decl.staticProperties.first(where: { $0.name == "columns" }),
                      columns.type == .list(.named("DisplayColumn")) else {
                    throw TypeError("\(decl.name) can't be Tabular without a static 'columns' of [DisplayColumn]: static let columns: [DisplayColumn] = [\"name\"]")
                }
                continue
            }
            for property in decl.properties where property.getter == nil {
                if let type = property.type, !conforms(type, to: proto) {
                    throw TypeError("\(decl.name) can't be \(proto): its '\(property.name)' is \(type), which isn't")
                }
            }
        }
        for index in decl.properties.indices {
            let property = decl.properties[index]
            if let getter = property.getter {
                var function = FunctionDecl(name: property.name, parameters: [], returnType: property.type, body: getter)
                try checkFunction(&function, self: selfType)
                decl.properties[index].getter = function.body
            } else if property.defaultValue != nil, let type = property.type {
                try expect(&decl.properties[index].defaultValue!, type, "\(decl.name).\(property.name)'s default")
            }
        }
        for index in decl.methods.indices {
            try checkFunction(&decl.methods[index], self: selfType, mutating: decl.methods[index].isMutating)
        }
        for index in decl.staticProperties.indices {
            let property = decl.staticProperties[index]
            if let getter = property.getter {
                var function = FunctionDecl(name: property.name, parameters: [], returnType: property.type, body: getter)
                try checkFunction(&function)
                decl.staticProperties[index].getter = function.body
            } else if var value = property.defaultValue {
                if let type = property.type {
                    try expect(&value, type, "\(decl.name).\(property.name)'s value")
                } else {
                    // Its type is its value's, which the struct's other
                    // checks can now use.
                    decl.staticProperties[index].type = try typeOf(&value)
                    if case .structType(var info)? = scopes[scopes.count - 1][decl.name] {
                        info.staticProperties[index].type = decl.staticProperties[index].type
                        scopes[scopes.count - 1][decl.name] = .structType(info)
                    }
                }
                decl.staticProperties[index].defaultValue = value
            }
        }
        for index in decl.staticMethods.indices {
            try checkFunction(&decl.staticMethods[index])
        }
        for index in decl.initializers.indices {
            var function = decl.initializers[index]
            function.name = "\(decl.name).init"
            try checkFunction(&function, self: selfType, initializing: true)
            function.name = "init"
            decl.initializers[index] = function
        }
    }

    @_spi(Shell) public func enumInfo(_ decl: EnumDecl) -> EnumInfo {
        EnumInfo(name: decl.name, cases: decl.cases.map { ($0.name, $0.associated) }, rawType: decl.rawType,
                 conformances: decl.conformances)
    }

    @_spi(Shell) public func checkEnum(_ decl: inout EnumDecl) throws {
        for proto in decl.conformances where proto != "CustomStringConvertible" {
            if proto == "Tabular" { throw TypeError("\(decl.name) can't be Tabular: only a struct can, as a table is made of records") }
            // Iterating needs a `makeIterator` of its own, which nothing declared in Swish has yet.
            if proto == "Sequence" { throw TypeError("\(decl.name) can't be a Sequence yet") }
            for enumCase in decl.cases {
                for value in enumCase.associated where !conforms(value.type, to: proto) {
                    throw TypeError("\(decl.name) can't be \(proto): \(decl.name).\(enumCase.name) holds a \(value.type), which isn't")
                }
            }
        }
        guard let rawType = decl.rawType else { return }
        for index in decl.cases.indices where decl.cases[index].rawValue != nil {
            try expect(&decl.cases[index].rawValue!, rawType, "\(decl.name).\(decl.cases[index].name)'s raw value")
        }
    }
}
