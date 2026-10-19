import Foundation

// What a host can ask of the names a script can use: the functions, methods, properties, variables and types there are, which
// overload a call means, and the type of an expression. One lookup for everything a name can mean.

/// A function, method, property, variable or type a script can name.
public struct Symbol: Sendable, Hashable {
    /// What a name is. A type says what it was declared as.
    public enum Kind: Sendable { case function, method, property, variable, structure, enumeration, `class`, actor, `protocol` }

    /// A parameter of a function or method.
    public struct Parameter: Sendable, Hashable {
        /// The argument label; nil when the argument is written without one.
        public var label: String?
        /// The name the function's body uses.
        public var name: String
        public var type: ValueType
        /// Whether a call may leave it out.
        public var hasDefault: Bool
        public var isVariadic: Bool
        /// Receives what is piped in, as a `@Input` parameter does.
        public var isInput: Bool

        public init(label: String? = nil, name: String, type: ValueType = .any, hasDefault: Bool = false, isVariadic: Bool = false, isInput: Bool = false) {
            self.label = label
            self.name = name
            self.type = type
            self.hasDefault = hasDefault
            self.isVariadic = isVariadic
            self.isInput = isInput
        }
    }

    public var name: String
    public var kind: Kind
    /// The line `help` shows, when it has one.
    public var summary: String?
    public var parameters: [Parameter]
    /// What it gives back, nil when nothing; for a variable, property or type, its type.
    public var returns: ValueType?
    public var isThrowing: Bool
    public var isMutating: Bool
    public var isAsync: Bool

    public init(
        name: String, kind: Kind, summary: String? = nil, parameters: [Parameter] = [], returns: ValueType? = nil,
        isThrowing: Bool = false, isMutating: Bool = false, isAsync: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.parameters = parameters
        self.returns = returns
        self.isThrowing = isThrowing
        self.isMutating = isMutating
        self.isAsync = isAsync
    }

    /// Its type as a value: the function type of a function or method (parameter types in order, what it returns), or the type
    /// of a variable, property or type.
    public var type: ValueType {
        switch kind {
        case .function, .method: .function(parameters: parameters.map(\.type), returns: returns ?? .tuple([]))
        default: returns ?? .any
        }
    }

    /// As a pipeline stage sees it: the parameter that receives what is piped in removed.
    public func droppingInput() -> Symbol {
        var copy = self
        copy.parameters.removeAll { $0.isInput }
        return copy
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
    }

    private func symbols(of name: String, binding: Binding) -> [Symbol] {
        switch binding.value {
        case .function(let callable):
            let candidates = (callable as? OverloadSet)?.candidates ?? (callable as? Function).map { [$0] } ?? []
            return candidates.map { symbol(of: $0, named: name, kind: .function) }
        case .object(let type as StructType): _ = type; return [Symbol(name: name, kind: .structure, returns: .named(name))]
        case .object(is EnumType): return [Symbol(name: name, kind: .enumeration, returns: .named(name))]
        case .object(let type as ClassType): return [Symbol(name: name, kind: type.isActor ? .actor : .class, returns: .named(name))]
        case .object(is ProtocolType): return [Symbol(name: name, kind: .protocol, returns: .named(name))]
        default:
            let checker = TypeChecker(interpreter: self)
            return [Symbol(name: name, kind: .variable, returns: ValueType(checker.type(of: binding.value)))]
        }
    }

    private func symbol(of function: Function, named name: String, kind: Symbol.Kind) -> Symbol {
        Symbol(
            name: function.name ?? name, kind: kind, summary: function.documentation.map(\.summary).flatMap { $0.isEmpty ? nil : $0 },
            parameters: function.parameters.map {
                Symbol.Parameter(label: $0.label, name: $0.name, type: ValueType($0.type), hasDefault: $0.defaultValue != nil || $0.externalDefault != nil,
                                 isVariadic: $0.variadic, isInput: $0.isInput)
            },
            returns: function.returnType.flatMap { $0 == .void ? nil : ValueType($0) },
            isThrowing: function.isThrowing, isMutating: function.isMutating, isAsync: function.effect != .sync)
    }

    private func memberSymbols(named name: String?, of type: TypeAnnotation) -> [Symbol] {
        let checker = TypeChecker(interpreter: self)
        var found: [Symbol] = []
        func add(_ signature: TypeChecker.Signature, kind: Symbol.Kind, dropping receiver: Bool = false) {
            var parameters = signature.parameters
            if receiver, parameters.first?.isInput == true || parameters.first?.name == "self" { parameters.removeFirst() }
            found.append(Symbol(
                name: signature.name, kind: kind,
                parameters: parameters.map {
                    Symbol.Parameter(label: $0.label, name: $0.name, type: ValueType($0.type), hasDefault: $0.defaultValue != nil || $0.externalDefault != nil,
                                     isVariadic: $0.variadic, isInput: $0.isInput)
                },
                returns: signature.returns == .void ? nil : ValueType(signature.returns),
                isThrowing: signature.isThrowing, isMutating: signature.isMutating, isAsync: signature.effect != .sync))
        }
        // A struct's, enum's or host object's own.
        if let profile = checker.describe(type) {
            for (member, signatures) in profile.declared.methods where name == nil || name == member { signatures.forEach { add($0, kind: .method) } }
            for (member, signatures) in profile.extended.methods where name == nil || name == member { signatures.forEach { add($0, kind: .method) } }
            for (member, property) in profile.declared.properties where name == nil || name == member {
                found.append(Symbol(name: member, kind: .property, returns: ValueType(property.type)))
            }
        }
        // A bridged Swift type's.
        if let (bridgedType, bindings) = checker.bridged(type) {
            for member in bridgedType.members where !member.isStatic && member.kind != .initializer && member.kind != .setter && (name == nil || name == member.name) {
                let isMethod = member.kind == .method
                found.append(Symbol(
                    name: member.name, kind: isMethod ? .method : .property, summary: member.summary.isEmpty ? nil : member.summary,
                    parameters: member.parameters.map {
                        Symbol.Parameter(label: $0.label, name: $0.name, type: ValueType(checker.substitute($0.type, bindings)),
                                         hasDefault: $0.defaultValue != nil || $0.externalDefault != nil, isVariadic: $0.variadic)
                    },
                    returns: member.returns == .void ? nil : ValueType(checker.substitute(member.returns, bindings)),
                    isThrowing: member.isThrowing, isMutating: member.isMutating, isAsync: member.effect != .sync))
            }
        }
        // What every sequence has.
        if case .list(let element) = type {
            for (member, set) in sequenceMethods where name == nil || name == member {
                for signature in checker.sequenceSignatures(set) {
                    var made = signature
                    made.parameters = made.parameters.map { var p = $0; p.type = checker.substitute(p.type, ["Element": element]); return p }
                    made.returns = checker.substitute(made.returns, ["Element": element])
                    add(made, kind: .method, dropping: true)
                }
            }
        }
        return found
    }

    /// Which of the candidates a call with these arguments means: by their labels and types, the one that fits with the
    /// fewest conversions. Throws the checker's own complaint when none fits or several do.
    public func resolveOverload(among candidates: [Symbol], arguments: [ValueType.Element]) throws(Diagnostic) -> Symbol {
        guard !candidates.isEmpty else { throw Diagnostic(kind: .type, message: "there is nothing to call") }
        let checker = TypeChecker(interpreter: self)
        func penalty(_ candidate: Symbol) -> Int? {
            let parameters = candidate.parameters.filter { !$0.isInput }
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

extension Interpreter {
    // MARK: Host types

    /// Describes the objects whose `typeName` is `name`, for the checker: the protocol they are used as.
    /// `describe(type: "Node", as: "var label: String { get }; func rename(to: String) throws")` lets a script use a
    /// `Node` with its members checked before it runs, and pass one where a `Node` is asked for. The description is
    /// the host's promise; `missingMembers(of:)` checks an object against it.
    public func describe(type name: String, as members: String) throws(Diagnostic) {
        _ = try evaluate("protocol \(name) { \(members) }")
    }

    /// What the description of `object`'s type asks that the object doesn't have (the names of its members), or
    /// nothing if it has them all or its type hasn't been described.
    public func missingMembers(of object: some HostObject) -> [String] {
        guard let description = protocolType(named: object.typeName)?.declaration else { return [] }
        let required = description.properties.map(\.name) + description.methods.map(\.name)
        let present = Set(object.memberNames)
        return required.filter { !present.contains($0) }
    }
}
