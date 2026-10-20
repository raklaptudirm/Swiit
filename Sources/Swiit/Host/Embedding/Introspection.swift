import Foundation

// What a host can ask of the names a script can use: the functions, methods, properties, variables and types there are, which
// overload a call means, and the type of an expression. One lookup for everything a name can mean.

/// Something a script can name: a function or method, a variable or property, or a type. Only a function has parameters and
/// effects, only a variable can be settable, only a type has a declaration kind: what a symbol is decides what it has.
public struct Symbol: Sendable, Hashable {
    /// What a name stands for, in a word.
    public enum Role: Sendable { case variable, function, type }

    public var name: String
    /// The line `help` shows, when it has one.
    public var summary: String?
    public var declaration: Declaration
    /// Whether the core or the host provides it, as opposed to a script's own declaration.
    public var isBuiltin = false

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
        /// What it asks of its type parameters, by name: `["Element": ["Comparable"]]` for `sorted()`. A protocol written `=Int`
        /// is a type it must be exactly.
        public var generics: [String: [String]]

        public init(parameters: [Parameter] = [], returns: ValueType? = nil, isThrowing: Bool = false, isAsync: Bool = false,
                    isMutating: Bool = false, generics: [String: [String]] = [:]) {
            self.generics = generics
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
    /// Everything a name can mean: with no `type`, the globals (functions, variables and types, all of them without a `name`,
    /// the core's builtins too);
    /// with one, the members a value of that type has (a struct's or host object's methods and properties, a bridged type's,
    /// the sequence methods of a list).
    public func symbols(named name: String? = nil, of type: ValueType? = nil) -> [Symbol] {
        withMainTask {
            guard let type else { return globalSymbols(named: name) }
            var annotation = TypeAnnotation(type)
            // A generic Swift type by its bare name has members whatever it holds: `Array`, `Set`.
            if case .named(let typeName) = annotation, let generic = Bridge.types[typeName]?.genericParameters, !generic.isEmpty {
                annotation = .generic(typeName, generic.map { _ in .unknown })
            }
            return memberSymbols(named: name, of: annotation)
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
        // What was declared, then the core's builtins it doesn't shadow.
        let declared = scopes[1].bindings
        let core = scopes[0].bindings.filter { declared[$0.key] == nil }
        return (declared.sorted { $0.key < $1.key } + core.sorted { $0.key < $1.key }).flatMap { symbols(of: $0.key, binding: $0.value) }
    }

    private func symbols(of name: String, binding: Binding) -> [Symbol] {
        switch binding.value {
        case .function(let callable):
            let candidates = (callable as? OverloadSet)?.candidates ?? (callable as? Function).map { [$0] } ?? []
            return candidates.map { function in
                var symbol = Symbol(name: function.name ?? name, summary: function.documentation.map(\.summary).flatMap { $0.isEmpty ? nil : $0 },
                       declaration: .function(Symbol.Function(
                           parameters: function.parameters.map { parameter($0, documentation: function.documentation?.parameters[$0.name]) },
                           returns: function.returnType.flatMap { $0 == .void ? nil : ValueType($0) },
                           isThrowing: function.isThrowing, isAsync: function.effect != .sync, isMutating: function.isMutating,
                           generics: function.generics)))
                symbol.isBuiltin = function.isBuiltin
                return symbol
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
                isThrowing: signature.isThrowing, isAsync: signature.effect != .sync, isMutating: signature.isMutating,
                generics: signature.generics))))
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
                            isThrowing: member.isThrowing, isAsync: member.effect != .sync, isMutating: member.isMutating,
                            generics: member.generics))))
                } else {
                    found.append(Symbol(
                        name: member.name, summary: member.summary.isEmpty ? nil : member.summary,
                        declaration: .variable(ValueType(checker.substitute(member.returns, bindings)), isSettable: settable.contains(member.name))))
                }
            }
        }
        // What every sequence has: what the host's prelude adds to `Sequence`, which `symbols(of: .named("Sequence"))` lists alone.
        var holder: TypeAnnotation?
        if case .list(let element) = type { holder = element } else if case .named("Sequence") = type { holder = .unknown }
        if let element = holder {
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

    /// What each global name stands for, cheaply: the functions, variables and types a script can name, the core's builtins and
    /// Swift's own types included. How a front end tells a name it reads from one that is new.
    public func names() -> [String: Symbol.Role] {
        withMainTask {
            globalNames().compactMapValues { kind in
                switch kind {
                case .function: .function
                case .variable: .variable
                case .type: .type
                default: nil
                }
            }
        }
    }

    /// How to color Swift source, in characters, which may be half typed: what it reads before a problem is colored as it reads
    /// it.
    public func highlight(_ source: String) -> [Highlight] {
        let bound = withMainTask { globalNames() }
        return frontEnd.highlight(source, bound: bound).map { span in
            let kind: Highlight.Kind = switch span.kind {
            case .keyword: .keyword
            case .command: .command
            case .flag: .flag
            case .string: .string
            case .number: .number
            case .constant: .constant
            case .variable: .variable
            case .comment: .comment
            case .type: .type
            case .punctuation: .punctuation
            }
            return Highlight(range: span.range, kind: kind)
        }
    }

    /// A stretch of source and what it is.
    public struct Highlight: Sendable {
        public enum Kind: Sendable { case keyword, command, flag, string, number, constant, variable, comment, type, punctuation }
        public var range: Range<Int>
        public var kind: Kind
    }

    /// Every type a script can name, its members to be had from `symbols(of:)`: those scripts and the host declare, and Swift's
    /// own that the core bridges (`String`, `Array`, `Date`).
    public func types() -> [Symbol] {
        withMainTask {
            let declared = scopes[1].bindings.sorted { $0.key < $1.key }.flatMap { symbols(of: $0.key, binding: $0.value) }.filter {
                if case .type = $0.declaration { true } else { false }
            }
            let bridged = scopes[0].bindings.sorted { $0.key < $1.key }.compactMap { name, binding -> Symbol? in
                if case .object(is BridgedTypeName) = binding.value {
                    var symbol = Symbol(name: name, declaration: .type(.structure))
                    symbol.isBuiltin = true
                    return symbol
                } else { return nil }
            }
            return declared + bridged
        }
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
    public func check(_ source: String) throws(Diagnostic) -> Declarations {
        do {
            return try inCurrentTask { () throws -> Declarations in
                switch parse(source) {
                case .failure(let error): throw Diagnostic(kind: .syntax, message: error.description, range: error.range, isIncomplete: error.incomplete)
                case .success(let program):
                    let checker = TypeChecker(interpreter: self)
                    do {
                        _ = try checker.check(program)
                    } catch let error as TypeError {
                        throw Diagnostic(kind: .type, message: error.message, line: error.line, range: error.spot ?? error.range)
                    }
                    var declarations = Declarations(symbols: checker.scopes[0].sorted { $0.key < $1.key }.flatMap { declaredSymbols(of: $0.key, $0.value) })
                    for case (let name, .enumType(let profile)) in checker.scopes[0] {
                        declarations.enumerations[name] = Declarations.Enumeration(
                            cases: profile.cases.filter { $0.payload.isEmpty }.map(\.name), hasRawValues: profile.rawType != nil)
                    }
                    return declarations
                }
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// What a checked program declares at its top level.
    public struct Declarations: Sendable {
        /// Its functions, types and variables.
        public var symbols: [Symbol]
        /// Its enums, by name, for reading a word against one before the enum exists.
        public var enumerations: [String: Enumeration] = [:]

        public struct Enumeration: Sendable {
            /// The cases without associated values.
            public var cases: [String]
            public var hasRawValues: Bool
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
                case .failure(let error): throw Diagnostic(kind: .syntax, message: error.description, range: error.range, isIncomplete: error.incomplete)
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
        } catch {
            throw Diagnostic.of(error)
        }
    }
}
