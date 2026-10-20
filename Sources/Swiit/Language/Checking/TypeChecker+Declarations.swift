import Foundation

extension TypeChecker {
    // MARK: Declarations

    /// Adds `decl` to its name's overloads, in the order the interpreter
    /// keeps them: one with the same parameters replaces the old.
    func declareFunction(_ decl: FunctionDecl) {
        var overloads: [Signature] = []
        if case .functions(let existing)? = scopes[scopes.count - 1][decl.name] {
            overloads = existing
        } else if scopes.count == 1, let binding = interpreter.scopes.last?.bindings[decl.name], binding.isFunction,
                  case .function(let set as OverloadSet) = binding.value {
            // At the top, it joins what earlier entries declared.
            overloads = set.candidates.map(signature)
        } else if scopes.count == 1, let binding = interpreter.scopes.first?.bindings[decl.name], binding.isFunction,
                  case .function(let set as OverloadSet) = binding.value {
            // A builtin of that name is overloaded, not replaced.
            overloads = set.candidates.map(signature)
        }
        overloads.removeAll { sameParameters($0.parameters, decl.parameters) && $0.generics == decl.generics }
        var declared = Signature(
            name: decl.name, parameters: decl.parameters, returns: decl.returnType ?? .void, isThrowing: decl.isThrowing,
            isRethrowing: decl.isRethrowing, effect: decl.effect, generics: decl.generics
        )
        declared.thrownType = decl.thrownType
        declared.typeParameters = decl.runtimeTypeParameters
        overloads.append(declared)
        for index in overloads.indices { overloads[index].index = index }
        scopes[scopes.count - 1][decl.name] = .functions(overloads)
    }

    func sameParameters(_ a: [Parameter], _ b: [Parameter]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.label == $1.label && $0.type == $1.type && $0.variadic == $1.variadic }
    }

    /// A body written for the result builder `name`, as the plain code it stands for.
    func resultBuilt(_ body: Program, by name: String) throws -> Program {
        guard let info = structInfo(named: name) else { throw TypeError("@\(name) is not a result builder") }
        var transform = ResultBuilderTransform(builder: name, methods: Set(info.declared.staticMethods.keys))
        do { return try transform.transform(body) } catch let error as SyntaxError { throw TypeError(error.description) }
    }

    func checkFunction(
        _ decl: inout FunctionDecl, self selfType: TypeAnnotation? = nil, mutating: Bool = false, initializing: Bool = false
    ) throws {
        if let builder = decl.resultBuilder {
            decl.body = try resultBuilt(decl.body, by: builder)
            decl.resultBuilder = nil
        }
        var names: [String: Symbol] = [:]
        for index in decl.parameters.indices {
            let parameter = decl.parameters[index]
            if decl.parameters[index].defaultValue != nil {
                try expect(&decl.parameters[index].defaultValue!, parameter.type, "\(parameter.name)'s default")
            }
            // A type parameter isn't known in the body: values of it can be used as any.
            let known = substitute(parameter.type, [:])
            names[parameter.name] = .variable(parameter.variadic ? .list(known) : known, mutable: parameter.isInout)
        }
        // A type parameter is a value in the body too (`T()`, `T.self`), of a type that isn't known there.
        for parameter in decl.generics.keys where names[parameter] == nil { names[parameter] = .variable(.unknown, mutable: false) }
        if let selfType { names["self"] = .variable(selfType, mutable: mutating || initializing) }
        // `super` is the class above, as `self`.
        if case .named(let className)? = selfType, let info = structInfo(named: className), let parent = info.superclass {
            names["super"] = .variable(.named(parent), mutable: true)
        }
        if initializing { names[InternalName.initializing] = .variable(.void, mutable: false) }
        // `init?` may `return nil`.
        let result = decl.isFailable ? TypeAnnotation.optional(.void) : substitute(decl.returnType ?? .void, [:])
        try checkBecomingAsync(decl)
        let topLevel = effectContexts.count == 1
        returns.append(ReturnContext(declared: result))
        errorContexts.append(ErrorContext(handled: decl.isThrowing || decl.isRethrowing, boundary: .function(decl.name), thrown: decl.thrownType))
        scopes.append(names)
        defer {
            returns.removeLast()
            errorContexts.removeLast()
            scopes.removeLast()
        }

        // `await` only in an `async` function.
        let (_, effects) = try withEffects(allowsAwait: decl.isAsync) { () throws in
            // A body that's one expression is the result, when there's one.
            if result != .void, var expr = implicitReturn(decl.body) {
                try expect(&expr, result, "\(decl.name)'s result")
                decl.body.statements[0] = .expression(expr)
                return
            }
            try checkBlock(&decl.body)
            if result != .void && result != .unknown && !decl.isFailable && !definitelyReturns(decl.body) {
                throw TypeError("\(decl.name) must return \(result) on every path")
            }
        }
        if topLevel { topLevelUnawaited[decl.name] = effects.unawaited }
    }

    func implicitReturn(_ body: Program) -> Expr? {
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
    func definitelyReturns(_ program: Program) -> Bool {
        definitelyLeaves(program, orExits: false)
    }

    /// Whether running `program` always leaves it: by `return`, or, with
    /// `orExits` (for a guard's `else`), by `break`, `continue` or `exit`.
    func definitelyLeaves(_ program: Program, orExits: Bool) -> Bool {
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
        case .doCatch(let body, let clauses):
            return leaves(body) && clauses.allSatisfy { leaves($0.body) }
        case .throwStatement:
            return true
        case .ifStatement(let node):
            guard let otherwise = node.otherwise else { return false }
            return leaves(node.then) && leaves(otherwise)
        case .switchStatement(let node):
            // A switch always matches (or fails), so every case returning is enough.
            return !node.cases.isEmpty && node.cases.allSatisfy { leaves($0.body) }
        // What never comes back.
        case .expression(.call(.variable("fatalError"), _)), .expression(.call(.variable("preconditionFailure"), _)):
            return true
        case .expression(.call(.variable("exitShell"), _)) where orExits:
            return true
        default:
            return false
        }
    }

    func structInfo(_ decl: StructDecl) throws -> TypeProfile {
        var methods: [String: [Signature]] = [:]
        for method in decl.methods {
            var signature = Signature(name: method.name, parameters: method.parameters, returns: method.returnType ?? .void,
                                      isMutating: method.isMutating, isThrowing: method.isThrowing)
            signature.thrownType = method.thrownType
            signature.index = methods[method.name]?.count ?? 0
            methods[method.name, default: []].append(signature)
        }
        var stored: [PropertyDecl] = []
        for var property in decl.properties where property.getter == nil {
            // An untyped property takes its default's type.
            if property.type == nil, var defaultValue = property.defaultValue {
                // A lazy one may use `self`, which isn't there yet: its type is found when the body is checked.
                property.type = property.isLazy ? ((try? typeOf(&defaultValue)) ?? .unknown) : try typeOf(&defaultValue)
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
            Signature(name: "\(decl.name).init", parameters: initializer.parameters,
                      returns: initializer.isFailable ? .optional(.named(decl.name)) : .named(decl.name),
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
        var profile = TypeProfile(name: decl.name, kind: .structure)
        profile.conformances = decl.conformances
        profile.memberwise = memberwise
        for property in decl.properties where property.getter != nil {
            profile.declared.properties[property.name] = MemberProperty(type: property.type ?? .unknown, isSettable: property.setter != nil, stored: nil)
        }
        for property in stored { profile.declared.properties[property.name] = MemberProperty(type: property.type ?? .unknown, isSettable: property.mutable, stored: property) }
        profile.declared.methods = methods
        profile.declared.initializers = initializers
        for property in decl.staticProperties { profile.declared.staticProperties[property.name] = MemberProperty(staticDeclaration: property) }
        profile.declared.staticMethods = staticMethods
        for (index, declared) in decl.subscripts.enumerated() {
            profile.subscripts.append(Signature(name: "subscript", parameters: declared.parameters, returns: declared.returnType, index: index))
            profile.subscriptSettable.append(declared.setter != nil)
        }
        return profile
    }

    func checkStruct(_ decl: inout StructDecl, isClass: Bool = false) throws {
        let selfType = TypeAnnotation.named(decl.name)
        // Equatable, Hashable and Encodable come from the fields, which must
        // have them too; Comparable would need a `<` of its own.
        for proto in decl.conformances {
            // A protocol of the program's asks what it says.
            if protocolInfo(named: proto) != nil {
                try checkConformance(of: decl.name, to: proto)
                continue
            }
            // What a class conforms to by saying so isn't made from its fields.
            if isClass { continue }
            if proto == "Comparable", !decl.staticMethods.contains(where: { $0.name == "<" }) {
                throw TypeError("\(decl.name) can't be Comparable without a '<' of its own: static func < (a: \(decl.name), b: \(decl.name)) -> Bool")
            }
            // Iterating needs a `makeIterator` of its own, which nothing declared in Swiit has yet.
            if proto == "Sequence" { throw TypeError("\(decl.name) can't be a Sequence yet") }
            guard !TypeChecker.askNothingOfMembers.contains(proto) else { continue }
            for property in decl.properties where property.getter == nil {
                if let type = property.type, !conforms(type, to: proto) {
                    throw TypeError("\(decl.name) can't be \(proto): its '\(property.name)' is \(type), which isn't")
                }
            }
        }
        for index in decl.properties.indices {
            let property = decl.properties[index]
            // Observers see the property's value, and may change the rest of the struct.
            if property.getter == nil {
                for (observer, name) in [(property.willSet, property.willSetName), (property.didSet, property.didSetName)] {
                    guard let body = observer else { continue }
                    var function = FunctionDecl(name: property.name, parameters: [Parameter(name: name, type: property.type ?? .unknown)],
                                                returnType: nil, body: body)
                    try checkFunction(&function, self: selfType, mutating: true)
                    if body == property.willSet && name == property.willSetName { decl.properties[index].willSet = function.body }
                    else { decl.properties[index].didSet = function.body }
                }
            }
            if let getter = property.getter {
                var function = FunctionDecl(name: property.name, parameters: [], returnType: property.type, body: getter)
                try checkFunction(&function, self: selfType)
                decl.properties[index].getter = function.body
                if let setter = property.setter {
                    var function = FunctionDecl(name: property.name, parameters: [Parameter(name: property.setterName, type: property.type ?? .unknown)],
                                                returnType: nil, body: setter)
                    try checkFunction(&function, self: selfType, mutating: true)
                    decl.properties[index].setter = function.body
                }
            } else if property.defaultValue != nil, let type = property.type {
                // A lazy one is worked out with `self`.
                if property.isLazy { scopes.append(["self": .variable(selfType, mutable: true)]) }
                defer { if property.isLazy { scopes.removeLast() } }
                try expect(&decl.properties[index].defaultValue!, type, "\(decl.name).\(property.name)'s default")
            }
        }
        for index in decl.methods.indices {
            try checkFunction(&decl.methods[index], self: selfType, mutating: isClass || decl.methods[index].isMutating)
        }
        for index in decl.subscripts.indices {
            let declared = decl.subscripts[index]
            var getter = FunctionDecl(name: "subscript", parameters: declared.parameters, returnType: declared.returnType, body: declared.getter)
            try checkFunction(&getter, self: selfType)
            decl.subscripts[index].getter = getter.body
            if let body = declared.setter {
                var setter = FunctionDecl(name: "subscript", parameters: declared.parameters + [Parameter(name: declared.setterName, type: declared.returnType)],
                                          returnType: nil, body: body)
                try checkFunction(&setter, self: selfType, mutating: true)
                decl.subscripts[index].setter = setter.body
            }
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
                        info.declared.staticProperties[property.name] = MemberProperty(staticDeclaration: decl.staticProperties[index])
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

    /// Protocols a type conforms to by saying so, whatever its members are:
    /// it describes itself, or can be thrown.
    static let askNothingOfMembers: Set<String> = Set(["CustomStringConvertible", "Error", "CaseIterable", "Sendable", "Decodable", "Codable", "AnyObject"])
        .union(looseProtocols)
    /// Swift's protocols that Swiit takes on trust: a type that says it has one is believed, and a generic asking for one is given any type.
    static let looseProtocols: Set<String> = [
        "Collection", "BidirectionalCollection", "RandomAccessCollection", "MutableCollection", "RangeReplaceableCollection",
        "Numeric", "SignedNumeric", "BinaryInteger", "FixedWidthInteger", "SignedInteger", "UnsignedInteger", "FloatingPoint",
        "BinaryFloatingPoint", "IteratorProtocol", "LosslessStringConvertible", "Identifiable",
        "ExpressibleByArrayLiteral", "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral",
    ]

    func enumInfo(_ decl: EnumDecl) -> TypeProfile {
        func signatures(_ declared: [FunctionDecl]) -> [String: [Signature]] {
            var result: [String: [Signature]] = [:]
            for method in declared {
                var signature = Signature(name: method.name, parameters: method.parameters, returns: method.returnType ?? .void,
                                          isMutating: method.isMutating, isThrowing: method.isThrowing)
                signature.index = result[method.name]?.count ?? 0
                result[method.name, default: []].append(signature)
            }
            return result
        }
        var profile = TypeProfile(name: decl.name, kind: .enumeration)
        profile.cases = decl.cases.map { ($0.name, $0.associated) }
        profile.rawType = decl.rawType
        profile.conformances = decl.conformances
        profile.typeParameters = decl.typeParameters
        for property in decl.properties where property.getter != nil {
            profile.declared.properties[property.name] = MemberProperty(type: property.type ?? .unknown, isSettable: false, stored: nil)
        }
        profile.declared.methods = signatures(decl.methods)
        for property in decl.staticProperties { profile.declared.staticProperties[property.name] = MemberProperty(staticDeclaration: property) }
        profile.declared.staticMethods = signatures(decl.staticMethods)
        profile.declared.initializers = decl.initializers.enumerated().map { index, initializer in
            Signature(name: "\(decl.name).init", parameters: initializer.parameters,
                      returns: initializer.isFailable ? .optional(.named(decl.name)) : .named(decl.name),
                      isMutating: true, isThrowing: initializer.isThrowing, index: index)
        }
        profile.addSynthesizedEnumMembers()
        return profile
    }

    func checkEnum(_ decl: inout EnumDecl) throws {
        for proto in decl.conformances where !TypeChecker.askNothingOfMembers.contains(proto) {
            if protocolInfo(named: proto) != nil { try checkConformance(of: decl.name, to: proto); continue }
            // Iterating needs a `makeIterator` of its own, which nothing declared in Swiit has yet.
            if proto == "Sequence" { throw TypeError("\(decl.name) can't be a Sequence yet") }
            for enumCase in decl.cases {
                for value in enumCase.associated where !conforms(value.type, to: proto) {
                    throw TypeError("\(decl.name) can't be \(proto): \(decl.name).\(enumCase.name) holds a \(value.type), which isn't")
                }
            }
        }
        if let rawType = decl.rawType {
            for index in decl.cases.indices where decl.cases[index].rawValue != nil {
                try expect(&decl.cases[index].rawValue!, rawType, "\(decl.name).\(decl.cases[index].name)'s raw value")
            }
        }
        // Its members, with the case as `self`.
        let selfType = TypeAnnotation.named(decl.name)
        for index in decl.properties.indices {
            let property = decl.properties[index]
            guard let getter = property.getter else { continue }
            var function = FunctionDecl(name: property.name, parameters: [], returnType: property.type, body: getter)
            try checkFunction(&function, self: selfType)
            decl.properties[index].getter = function.body
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
                    decl.staticProperties[index].type = try typeOf(&value)
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
}
