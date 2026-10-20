import Foundation

// What a host can ask of the names a script can use: the functions, methods, properties, variables and types there are, which
// overload a call means, and the type of an expression. One lookup for everything a name can mean.

/// Something a script can name: a function or method, a variable or property, or a type. Only a function has parameters and
/// effects, only a variable can be settable, only a type has a declaration kind: what a symbol is decides what it has.
public struct Symbol: Sendable, Hashable {
    public var name: String
    /// The line `help` shows, when it has one.
    public var summary: String?
    public var declaration: Declaration

    public enum Declaration: Sendable, Hashable {
        /// A function, or a method of a type.
        case function(Function)
        /// A global or a property: its type, and whether a script can assign to it.
        case variable(ValueType, isSettable: Bool)
        /// A type, and how it was declared.
        case type(TypeKind)
    }

    public struct Function: Sendable, Hashable {
        public var parameters: [Parameter]
        /// What it gives back, nil when nothing.
        public var returns: ValueType?
        public var isThrowing: Bool
        public var isAsync: Bool
        /// A method that changes its value.
        public var isMutating: Bool

        public init(parameters: [Parameter] = [], returns: ValueType? = nil, isThrowing: Bool = false, isAsync: Bool = false, isMutating: Bool = false) {
            self.parameters = parameters
            self.returns = returns
            self.isThrowing = isThrowing
            self.isAsync = isAsync
            self.isMutating = isMutating
        }
    }

    public enum TypeKind: Sendable { case structure, enumeration, `class`, actor, `protocol` }

    /// A parameter of a function.
    public struct Parameter: Sendable, Hashable {
        /// The argument label; nil when the argument is written without one.
        public var label: String?
        /// The name the function's body uses.
        public var name: String
        public var type: ValueType
        /// Whether a call may leave it out.
        public var hasDefault: Bool
        public var isVariadic: Bool
        /// What it is when the call leaves it out, if that is a plain value: `false`, `10`, `"-"`.
        public var defaultValue: Value?
        /// What a `- Parameter name:` line of its documentation says.
        public var documentation: String?

        public init(label: String? = nil, name: String, type: ValueType = .any, hasDefault: Bool = false, isVariadic: Bool = false,
                    defaultValue: Value? = nil, documentation: String? = nil) {
            self.label = label
            self.name = name
            self.type = type
            self.hasDefault = hasDefault
            self.isVariadic = isVariadic
            self.defaultValue = defaultValue
            self.documentation = documentation
        }
    }

    public init(name: String, summary: String? = nil, declaration: Declaration) {
        self.name = name
        self.summary = summary
        self.declaration = declaration
    }

    /// The function this is, if it is one.
    public var function: Function? {
        if case .function(let function) = declaration { function } else { nil }
    }

    /// Its type as a value: a function's is a function type (parameter types in order, what it returns); a variable's is its
    /// own; a type's is the type it names.
    public var type: ValueType {
        switch declaration {
        case .function(let function): .function(parameters: function.parameters.map(\.type), returns: function.returns ?? .tuple([]))
        case .variable(let type, _): type
        case .type: .named(name)
        }
    }
}

extension ValueType {
    /// The type an annotation names.
    @_spi(Layer) public init(_ annotation: TypeAnnotation) {
        self = switch annotation {
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .function: .callable
        case .record: .named("Record")
        case .named(let name): .named(name)
        case .list(let element): .list(ValueType(element))
        case .dictionary(let key, let value): .dictionary(ValueType(key), ValueType(value))
        case .optional(let wrapped): .optional(ValueType(wrapped))
        case .generic(let name, let arguments): .named(name, arguments.map(ValueType.init))
        case .tuple(let elements): .tuple(elements.map { ValueType.Element(label: $0.label, type: ValueType($0.type)) })
        case .functionType(let parameters, let returns, _, _): .function(parameters: parameters.map(ValueType.init), returns: ValueType(returns))
        case .keyPath(let root, let value): .named("KeyPath", [ValueType(root), ValueType(value)])
        // A type parameter (`Element`) is named, and nothing is declared under the name.
        case .parameter(let name): .named(name)
        case .void: .tuple([])
        default: .any
        }
    }
}

extension Interpreter {
    /// Everything a name can mean: with no `type`, the globals (functions, variables and types, all of them without a `name`);
    /// with one, the members a value of that type has (a struct's or host object's methods and properties, a bridged type's,
    /// the sequence methods of a list).
    public func symbols(named name: String? = nil, of type: ValueType? = nil) -> [Symbol] {
        withMainTask {
            guard let type else { return globalSymbols(named: name) }
            return memberSymbols(named: name, of: TypeAnnotation(type))
        }
    }

    /// The members a Swift type has for scripts: `symbols(named: "sorted", of: [Int].self)`.
    public func symbols<T: ValueConvertible>(named name: String? = nil, of type: T.Type) -> [Symbol] {
        symbols(named: name, of: ValueType(type))
    }

    private func globalSymbols(named name: String?) -> [Symbol] {
        if let name {
            return lookup(name).map { symbols(of: name, binding: $0) } ?? []
        }
        return scopes[1].bindings.sorted { $0.key < $1.key }.flatMap { symbols(of: $0.key, binding: $0.value) }
            + scopes[0].bindings.sorted { $0.key < $1.key }.compactMap { name, binding in
                // Swift's own types, which the core bridges: `String`, `Array`, `Date`.
                if case .object(is BridgedTypeName) = binding.value { Symbol(name: name, declaration: .type(.structure)) } else { nil }
            }
    }

    private func symbols(of name: String, binding: Binding) -> [Symbol] {
        switch binding.value {
        case .function(let callable):
            let candidates = (callable as? OverloadSet)?.candidates ?? (callable as? Function).map { [$0] } ?? []
            return candidates.map { function in
                Symbol(name: function.name ?? name, summary: function.documentation.map(\.summary).flatMap { $0.isEmpty ? nil : $0 },
                       declaration: .function(Symbol.Function(
                           parameters: function.parameters.map { parameter($0, documentation: function.documentation?.parameters[$0.name]) },
                           returns: function.returnType.flatMap { $0 == .void ? nil : ValueType($0) },
                           isThrowing: function.isThrowing, isAsync: function.effect != .sync, isMutating: function.isMutating)))
            }
        case .object(is StructType): return [Symbol(name: name, declaration: .type(.structure))]
        case .object(is EnumType): return [Symbol(name: name, declaration: .type(.enumeration))]
        case .object(let type as ClassType): return [Symbol(name: name, declaration: .type(type.isActor ? .actor : .class))]
        case .object(is ProtocolType): return [Symbol(name: name, declaration: .type(.protocol))]
        default:
            let checker = TypeChecker(interpreter: self)
            return [Symbol(name: name, declaration: .variable(ValueType(checker.type(of: binding.value)), isSettable: binding.mutable))]
        }
    }

    fileprivate func parameter(_ parameter: Parameter, documentation: String? = nil) -> Symbol.Parameter {
        var plain: Value?
        if case .literal(let value)? = parameter.defaultValue { plain = value }
        return Symbol.Parameter(label: parameter.label, name: parameter.name, type: ValueType(parameter.type),
                                hasDefault: parameter.defaultValue != nil || parameter.externalDefault != nil, isVariadic: parameter.variadic,
                                defaultValue: plain, documentation: documentation)
    }

    private func memberSymbols(named name: String?, of type: TypeAnnotation) -> [Symbol] {
        let checker = TypeChecker(interpreter: self)
        var found: [Symbol] = []
        func add(_ signature: TypeChecker.Signature, dropping receiver: Bool = false) {
            var parameters = signature.parameters
            if receiver, parameters.first?.name == "self" { parameters.removeFirst() }
            found.append(Symbol(name: signature.name, declaration: .function(Symbol.Function(
                parameters: parameters.map { parameter($0) }, returns: signature.returns == .void ? nil : ValueType(signature.returns),
                isThrowing: signature.isThrowing, isAsync: signature.effect != .sync, isMutating: signature.isMutating))))
        }
        // A struct's, enum's or host object's own.
        if let profile = checker.describe(type) {
            for (member, signatures) in profile.declared.methods where name == nil || name == member { signatures.forEach { add($0) } }
            for (member, signatures) in profile.extended.methods where name == nil || name == member { signatures.forEach { add($0) } }
            for (member, property) in profile.declared.properties where name == nil || name == member {
                found.append(Symbol(name: member, declaration: .variable(ValueType(property.type), isSettable: property.isSettable)))
            }
        }
        // A bridged Swift type's.
        if let (bridgedType, bindings) = checker.bridged(type) {
            let settable = Set(bridgedType.members.filter { $0.kind == .setter && !$0.isStatic }.map(\.name))
            for member in bridgedType.members where !member.isStatic && member.kind != .initializer && member.kind != .setter && (name == nil || name == member.name) {
                if member.kind == .method {
                    found.append(Symbol(
                        name: member.name, summary: member.summary.isEmpty ? nil : member.summary,
                        declaration: .function(Symbol.Function(
                            parameters: member.parameters.map {
                                Symbol.Parameter(label: $0.label, name: $0.name, type: ValueType(checker.substitute($0.type, bindings)),
                                                 hasDefault: $0.defaultValue != nil || $0.externalDefault != nil, isVariadic: $0.variadic,
                                                 documentation: member.parameterDocs[$0.name])
                            },
                            returns: member.returns == .void ? nil : ValueType(checker.substitute(member.returns, bindings)),
                            isThrowing: member.isThrowing, isAsync: member.effect != .sync, isMutating: member.isMutating))))
                } else {
                    found.append(Symbol(
                        name: member.name, summary: member.summary.isEmpty ? nil : member.summary,
                        declaration: .variable(ValueType(checker.substitute(member.returns, bindings)), isSettable: settable.contains(member.name))))
                }
            }
        }
        // What every sequence has.
        if case .list(let element) = type {
            for (member, set) in sequenceMethods where name == nil || name == member {
                for signature in checker.sequenceSignatures(set) {
                    var made = signature
                    made.parameters = made.parameters.map { var p = $0; p.type = checker.substitute(p.type, ["Element": element]); return p }
                    made.returns = checker.substitute(made.returns, ["Element": element])
                    add(made, dropping: true)
                }
            }
        }
        return found
    }

    /// Whether values of `type` have what the protocol named asks (`Comparable`, `Hashable`, `Sequence`, or one a script
    /// declares), as the checker reads it.
    public func conforms(_ type: ValueType, to protocolName: String) -> Bool {
        inCurrentTask { TypeChecker(interpreter: self).conforms(TypeAnnotation(type), to: protocolName) }
    }

    /// Which of the candidates a call with these arguments means: by their labels and types, the one that fits with the
    /// fewest conversions. Throws the checker's own complaint when none fits or several do.
    public func resolveOverload(among candidates: [Symbol], arguments: [ValueType.Element]) throws(Diagnostic) -> Symbol {
        guard !candidates.isEmpty else { throw Diagnostic(kind: .type, message: "there is nothing to call") }
        let checker = TypeChecker(interpreter: self)
        func penalty(_ candidate: Symbol) -> Int? {
            guard let parameters = candidate.function?.parameters else { return nil }
            var cost = 0
            var next = 0
            for argument in arguments {
                // The parameter this argument is for: by label, else the next without one.
                guard let index = parameters[next...].firstIndex(where: { $0.label == argument.label }) ?? parameters.firstIndex(where: { $0.isVariadic && $0.label == argument.label }) else { return nil }
                let parameter = parameters[index]
                let actual = TypeAnnotation(argument.type), expected = TypeAnnotation(parameter.type)
                guard checker.fits(actual, expected) else { return nil }
                if expected == .any || expected == .unknown { cost += 1 }
                next = parameter.isVariadic ? index : index + 1
            }
            // What is left out must have a default.
            let given = Set(arguments.compactMap { argument in parameters.first { $0.label == argument.label }?.name })
            for parameter in parameters where !given.contains(parameter.name) && !parameter.hasDefault && !parameter.isVariadic { return nil }
            return cost
        }
        let fitting = candidates.compactMap { candidate in penalty(candidate).map { (candidate, $0) } }
        guard let best = fitting.map(\.1).min() else {
            let shown = arguments.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }.joined(separator: ", ")
            throw Diagnostic(kind: .type, message: "\(candidates[0].name): no overload accepts (\(shown))")
        }
        let winners = fitting.filter { $0.1 == best }
        guard winners.count == 1 else {
            throw Diagnostic(kind: .type, message: "\(candidates[0].name): ambiguous call; \(winners.count) overloads match")
        }
        return winners[0].0
    }

    /// Checks a program as `evaluate` would, and stops there: nothing runs, so a mistake is found before any statement's effect
    /// happens. It says what the program declares at its top level (its functions, types and variables), which a host can
    /// check its own uses against, as a command line against the function it names.
    public func check(_ source: String) throws(Diagnostic) -> [Symbol] {
        do {
            return try inCurrentTask { () throws -> [Symbol] in
                switch parse(source) {
                case .failure(let error): throw Diagnostic(kind: .syntax, message: error.description, range: error.range)
                case .success(let program):
                    let checker = TypeChecker(interpreter: self)
                    do {
                        _ = try checker.check(program)
                    } catch let error as TypeError {
                        throw Diagnostic(kind: .type, message: error.message, line: error.line, range: error.spot ?? error.range)
                    }
                    return checker.scopes[0].sorted { $0.key < $1.key }.flatMap { declaredSymbols(of: $0.key, $0.value) }
                }
            }
        } catch let diagnostic as Diagnostic {
            throw diagnostic
        } catch {
            throw Diagnostic(kind: .runtime, message: "\(error)")
        }
    }

    private func declaredSymbols(of name: String, _ symbol: TypeChecker.Symbol) -> [Symbol] {
        switch symbol {
        case .functions(let signatures):
            return signatures.map { signature in
                Symbol(name: signature.name, declaration: .function(Symbol.Function(
                    parameters: signature.parameters.map { parameter($0) }, returns: signature.returns == .void ? nil : ValueType(signature.returns),
                    isThrowing: signature.isThrowing, isAsync: signature.effect != .sync, isMutating: signature.isMutating)))
            }
        case .structType: return [Symbol(name: name, declaration: .type(.structure))]
        case .enumType: return [Symbol(name: name, declaration: .type(.enumeration))]
        case .protocolType: return [Symbol(name: name, declaration: .type(.protocol))]
        case .variable(let type, let mutable): return [Symbol(name: name, declaration: .variable(ValueType(type), isSettable: mutable))]
        case .swiftType, .asyncLet: return []
        }
    }

    /// The type of an expression written at the top level: the globals are in scope, a script's locals are not.
    public func valueType(of expression: String) throws(Diagnostic) -> ValueType {
        do {
            return try withMainTask { () throws -> ValueType in
                switch parse(expression) {
                case .failure(let error): throw Diagnostic(kind: .syntax, message: error.description, range: error.range)
                case .success(let program):
                    guard program.statements.count == 1, case .expression(var expr) = program.statements[0] else {
                        throw Diagnostic(kind: .type, message: "valueType(of:) takes one expression")
                    }
                    do {
                        return ValueType(try TypeChecker(interpreter: self).typeOf(&expr))
                    } catch let error as TypeError {
                        throw Diagnostic(kind: .type, message: error.message, line: error.line, range: error.spot ?? error.range)
                    }
                }
            }
        } catch let diagnostic as Diagnostic {
            throw diagnostic
        } catch {
            throw Diagnostic(kind: .runtime, message: "\(error)")
        }
    }
}
