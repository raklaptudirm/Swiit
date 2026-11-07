import Foundation
import SwiftSyntax
import Synchronization

// What a host can ask of the names a script can use: the functions, methods, properties, variables
// and types there are, which overload a call means, and the type of an expression. One lookup for
// everything a name can mean.

extension Symbol {
    /// An attribute written on a declaration, as written: `@discardableResult` is a name with no
    /// arguments, `@available(*, deprecated)` is `available` with two. What an attribute means is up to
    /// whatever looks it up by name: the checker for some, a host for the rest.
    public struct Attribute: Sendable, Hashable {
        /// What follows the `@`.
        public var name: String
        /// The text between the parentheses, one element per comma-separated argument.
        public var arguments: [String]

        public init(name: String, arguments: [String] = []) {
            self.name = name
            self.arguments = arguments
        }
    }
}

extension Sequence where Element == Symbol.Attribute {
    /// Whether one named `name` is among them.
    public func contains(named name: String) -> Bool {
        contains { $0.name == name }
    }
}

/// Something a script can name: a function or method, a variable or property, or a type. Only a
/// function has parameters and effects, only a variable can be settable: what a symbol is, its kind,
/// decides what it has.
public struct Symbol: Sendable, Hashable {
    public var name: String
    /// The line `help` shows, when it has one.
    public var summary: String?
    public var kind: Kind
    /// The attributes it was declared with: `@discardableResult`, `@available(…)`, and the rest.
    public var attributes: [Symbol.Attribute] = []
    /// Whether the core or the host provides it, as opposed to a script's own declaration.
    public var isBuiltin = false
    /// The type's ID, for a type. Nil for any other symbol, and for a type described by `check`
    /// before the source is run, which declares nothing yet.
    public internal(set) var id: ID?

    /// Names a type, or stands where one would be: what `register` gives back, what
    /// `Symbol.ID(named:in:)` finds, what `Value.typeID` has, and what `ScriptType.named` and
    /// `Value.isInstance(of:)` take. A host gets one from the interpreter (`register`,
    /// `Symbol.ID(named:in:)`, `Symbol.id`, a value's `typeID`), and mints one only for a Swift type it
    /// registers (`init(hostType:)`).
    ///
    /// An ID is one of three kinds:
    /// - **Declared**: a type a script declares. It names one declaration, made once in this
    ///   process. Declaring `struct Point` again makes a new type with a new ID, and the old ID
    ///   keeps naming the old one. A host cannot make one; it comes from the interpreter, so a
    ///   misspelling cannot name a declaration. An ID from another interpreter is just one this
    ///   interpreter never made, and names nothing.
    /// - **Host**: a Swift type the host or the core provides (`Int`, `Array`, a registered
    ///   `FileSize`, an encoded Swift value), by the name `String(describing:)` gives the Swift
    ///   type, which has no module in it. Host types are process-wide and one per name, as the
    ///   registry they live in is: two Swift types of one name in different modules collide, and an
    ///   encoded value carries only the name. An ID of this kind may name nothing (a type not
    ///   registered, or an encoded value's), and `Symbol.ID.symbol(in:)` then gives nil.
    /// - **Parameter**: a generic parameter (`Element`), by name, with nothing declared under it.
    ///
    /// IDs are equal when they are the same kind and the same declaration, or the same name. They
    /// do not outlive the process.
    public struct ID: Sendable, Hashable, CustomStringConvertible {
        enum Kind: Sendable, Hashable { case declared(UInt64), host, parameter }

        let kind: Kind
        /// The type's name as a script writes it: for display, not identity. Two IDs can share a
        /// name and be different types (a type declared again), and a host ID is its name alone.
        public let name: String

        private init(_ kind: Kind, _ name: String) {
            self.kind = kind
            self.name = name
        }

        /// Whether this names a generic parameter (`Element`): a placeholder for a type, which
        /// nothing is declared under.
        public var isGenericParameter: Bool {
            if case .parameter = kind { true } else { false }
        }

        static func host(_ name: String) -> ID { ID(.host, name) }
        static func parameter(_ name: String) -> ID { ID(.parameter, name) }

        /// A new declaration's ID, from a counter shared by the process.
        static func declare(_ name: String) -> ID {
            ID(
                .declared(
                    counter.withLock {
                        $0 += 1; return $0
                    }
                ),
                name
            )
        }
        private static let counter = Mutex<UInt64>(0)

        /// The ID of a Swift type the host is about to register, for the places that need it
        /// before there is an interpreter to ask or before the type is registered: a `scriptType`
        /// that is a static property, a type's own members that name it. It equals the ID
        /// `register` gives for the type of that name, and the same name's in another interpreter,
        /// and can never equal a script's type. Everywhere else, pass around what `register` gave
        /// back, or ask `Symbol.ID(named:in:)`.
        public init(hostType name: String) { self.init(.host, name) }

        public var description: String { name }

        public static func == (lhs: ID, rhs: ID) -> Bool {
            switch (lhs.kind, rhs.kind) {
            case (.declared(let a), .declared(let b)): a == b
            case (.host, .host), (.parameter, .parameter): lhs.name == rhs.name
            default: false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch kind {
            case .declared(let token): hasher.combine(token)
            case .host: hasher.combine(0); hasher.combine(name)
            case .parameter: hasher.combine(1); hasher.combine(name)
            }
        }

        /// Swift's own, which scripts have and hosts match on.
        public static let any = ID.host("Any")
        public static let bool = ID.host("Bool")
        public static let int = ID.host("Int")
        public static let double = ID.host("Double")
        public static let string = ID.host("String")
        public static let array = ID.host("Array")
        public static let arraySlice = ID.host("ArraySlice")
        public static let set = ID.host("Set")
        public static let dictionary = ID.host("Dictionary")
        public static let optional = ID.host("Optional")
        public static let function = ID.host("Function")
        public static let keyPath = ID.host("KeyPath")
        public static let sequence = ID.host("Sequence")
        public static let rawRepresentable = ID.host("RawRepresentable")

        /// Lets a pattern say `case .named("Array", …)` inside the module, which a literal
        /// conformance would offer to every host.
        static func ~= (name: String, id: ID) -> Bool { id.name == name }
    }

    /// What a symbol is. A type is one of the five Swift declares; what it has is for
    /// `ScriptType.members(named:in:)` to say.
    public enum Kind: Sendable, Hashable {
        /// A function, as a script declares or a host registers one.
        case function(Function)
        /// A global: its type, and whether a script can assign to it.
        case variable(Variable)
        /// A method of a type: a function that also says whether it changes its value and whether
        /// it is the type's own.
        case method(Method)
        /// A property of a type: a variable that also says whether it is the type's own.
        case property(Property)
        /// An initializer of a type: what it takes, and the type it makes.
        case initializer(Function)
        /// A case of an enum: the values it carries (none for most), and its raw value when the
        /// enum has them.
        case enumCase(parameters: [Parameter], rawValue: Value?)
        case structure, enumeration, `class`, actor, `protocol`
    }

    /// A variable: its type, and whether a script can assign to it.
    public struct Variable: Sendable, Hashable {
        public var type: ScriptType
        public var isSettable: Bool

        public init(type: ScriptType, isSettable: Bool = false) {
            self.type = type
            self.isSettable = isSettable
        }
    }

    /// A function that belongs to a type.
    public struct Method: Sendable, Hashable {
        public var function: Function
        /// It changes its value.
        public var isMutating: Bool
        /// It belongs to the type itself, as a `static` member does, and not to a value of it.
        public var isStatic: Bool

        public init(function: Function, isMutating: Bool = false, isStatic: Bool = false) {
            self.function = function
            self.isMutating = isMutating
            self.isStatic = isStatic
        }
    }

    /// A variable that belongs to a type.
    public struct Property: Sendable, Hashable {
        public var variable: Variable
        /// It belongs to the type itself, as a `static` member does, and not to a value of it.
        public var isStatic: Bool

        public init(variable: Variable, isStatic: Bool = false) {
            self.variable = variable
            self.isStatic = isStatic
        }
    }

    public struct Function: Sendable, Hashable {
        public var parameters: [Parameter]
        /// What it gives back; `.void` when nothing.
        public var returns: ScriptType
        public var isThrowing: Bool
        public var isAsync: Bool
        /// What it asks of its type parameters, by name: `["Element": ["Comparable"]]` for
        /// `sorted()`. A protocol written `=Int` is a type it must be exactly.
        public var generics: [GenericParameter]

        public init(
            parameters: [Parameter] = [],
            returns: ScriptType = .void,
            isThrowing: Bool = false,
            isAsync: Bool = false,
            generics: [GenericParameter] = []
        ) {
            self.generics = generics
            self.parameters = parameters
            self.returns = returns
            self.isThrowing = isThrowing
            self.isAsync = isAsync
        }
    }

    /// A type parameter of a function, with what it asks of the type given for it:
    /// `sorted<Element: Comparable>`.
    public struct GenericParameter: Sendable, Hashable, ExpressibleByStringLiteral {
        public var name: String
        public var constraints: [Constraint]

        /// What a type must be to be given for a type parameter.
        public enum Constraint: Sendable, Hashable {
            /// It conforms to a protocol: `Comparable`, `Hashable`, or one a script declares.
            case conforms(to: ScriptType)
            /// It is exactly this type, as `where Element == Int` says.
            case equals(ScriptType)

            /// The module's own tables are written with the names of the types they mean.
            public static let comparable = Constraint.conforms(to: .named("Comparable"))
            public static let hashable = Constraint.conforms(to: .named("Hashable"))
            public static let equatable = Constraint.conforms(to: .named("Equatable"))

            static func conforms(to name: String) -> Constraint { .conforms(to: .named(name)) }
            static func equals(_ name: String) -> Constraint { .equals(.named(name)) }

            /// What one constraint is among others when they are compared: a protocol by its name,
            /// an exact type by that name after an `=`.
            var refinementKey: String {
                switch self {
                case .conforms(let proto): proto.description
                case .equals(let exact): "=" + exact.description
                }
            }
        }

        /// The parameter as a type, for a signature that uses it: `T` in `(T, T) -> T`.
        public var type: ScriptType { .named(.parameter(name)) }

        public init(name: String, constraints: [Constraint] = []) {
            self.name = name
            self.constraints = constraints
        }

        /// A type parameter with no constraints, by its name.
        public init(stringLiteral name: String) {
            self.init(name: name)
        }
    }

    /// A parameter of a function.
    public struct Parameter: Sendable, Hashable {
        /// The argument label; nil when the argument is written without one.
        public var label: String?
        /// The name the function's body uses.
        public var name: String
        public var type: ScriptType
        /// Whether a call must give it, may leave it out, or may give any number.
        public var arity: Arity
        /// The type as the checker has it, which tells a type parameter from a type of the same
        /// name.
        var annotation: TypeAnnotation?
        /// What a `- Parameter name:` line of its documentation says.
        public var documentation: String?
        /// What is given is shown as interpolation shows a value (`print`).
        var showsByType = false

        /// How many arguments a parameter takes.
        public enum Arity: Sendable, Hashable {
            case required
            /// A call may leave it out.
            case defaulted(Default)
            /// A call may give any number, as `FilePath...` does.
            case variadic

            /// What it is when the call leaves it out.
            public enum Default: Sendable, Hashable {
                /// A plain value: `false`, `10`, `"-"`.
                case value(Value)
                /// Only Swift can make it, like `Date()`.
                case computed
            }
        }

        public init(
            label: String? = nil,
            name: String,
            type: ScriptType = .any,
            arity: Arity = .required,
            documentation: String? = nil
        ) {
            self.label = label
            self.name = name
            self.type = type
            self.arity = arity
            self.documentation = documentation
        }
    }

    public init(
        name: String,
        summary: String? = nil,
        kind: Kind,
        attributes: [Symbol.Attribute] = []
    ) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.attributes = attributes
    }

    /// The function this is, if it is one: a function, a method or an initializer.
    public var function: Function? {
        switch kind {
        case .function(let function), .initializer(let function): function
        case .method(let method): method.function
        default: nil
        }
    }

    /// The variable this is, if it is one: a global or a property.
    public var variable: Variable? {
        switch kind {
        case .variable(let variable): variable
        case .property(let property): property.variable
        default: nil
        }
    }

    /// Whether it is a type: a struct, an enum, a class, an actor or a protocol.
    public var isType: Bool {
        switch kind {
        case .structure, .enumeration, .class, .actor, .protocol: true
        case .function, .variable, .method, .property, .initializer, .enumCase: false
        }
    }

    /// Its type as a value: a function's is a function type (parameter types in order, what it
    /// returns); a variable's is its own; a type's is the type it names.
    public var scriptType: ScriptType {
        switch kind {
        case .function, .method, .initializer:
            .function(
                parameters: function!.parameters.map(\.type),
                returns: function!.returns,
                isThrowing: function!.isThrowing,
                isAsync: function!.isAsync
            )
        case .variable, .property: variable!.type
        case .structure, .enumeration, .class, .actor, .protocol: .named(id ?? .host(name))
        case .enumCase: .any
        }
    }
}

extension ScriptType {
    /// The type an annotation names. `declared` says which declaration a name means, for the names
    /// of types a program declares; a name it does not know is a host type's.
    init(_ annotation: TypeAnnotation, declared: (String) -> Symbol.ID? = { _ in nil }) {
        func reference(_ name: String) -> Symbol.ID { declared(name) ?? .host(name) }
        func convert(_ annotation: TypeAnnotation) -> ScriptType {
            ScriptType(annotation, declared: declared)
        }
        self =
            switch annotation {
            case .bool: .bool
            case .int: .int
            case .double: .double
            case .string: .string
            case .function: .callable
            case .record: .named("Record")
            case .named(let name): .named(reference(name))
            case .list(let element): .list(convert(element))
            case .dictionary(let key, let value): .dictionary(convert(key), convert(value))
            case .optional(let wrapped): .optional(convert(wrapped))
            case .generic(let name, let arguments): .named(reference(name), arguments.map(convert))
            case .tuple(let elements):
                .tuple(
                    elements.map { ScriptType.Element(label: $0.label, type: convert($0.type)) }
                )
            case .functionType(let parameters, let returns, let throwing, let effect):
                .function(
                    parameters: parameters.map(convert),
                    returns: convert(returns),
                    isThrowing: throwing,
                    isAsync: effect == .async
                )
            case .keyPath(let root, let value):
                .named(.keyPath, [convert(root), convert(value)])
            // A type parameter (`Element`) is named, and nothing is declared under the name.
            case .parameter(let name): .named(.parameter(name))
            case .void: .tuple([])
            case .metatype(let type): .metatype(convert(type))
            default: .any
            }
    }
}

extension ScriptType {
    /// Whether values of this type have what the protocol asks (`Comparable`, `Hashable`,
    /// `Sequence`, or one a script declares), as the checker reads it. False for a type or a
    /// protocol that is a declaration `interpreter` no longer means by its name.
    public func conforms(to proto: Symbol.ID, in interpreter: Interpreter) -> Bool {
        interpreter.conforms(self, to: proto)
    }
}

extension Interpreter {
    /// The type an annotation names, with the names of declared types as their declarations' IDs.
    func scriptType(_ annotation: TypeAnnotation) -> ScriptType {
        ScriptType(annotation) { name in
            guard case .object(let object)? = self.lookup(name)?.value.storage else { return nil }
            return (object as? any DeclaredType)?.id
        }
    }
}

typealias GenericParameter = Symbol.GenericParameter

extension Interpreter {
    /// What the program and the host have declared for scripts to name: functions, variables and
    /// types, all of them without a `name`, the core's builtins too. `ScriptType.members(named:in:)`
    /// says what a type has.
    public func globals(named name: String? = nil) -> [Symbol] {
        withMainTask { globalSymbols(named: name) }
    }

    func members(of type: ScriptType, named name: String?) -> [Symbol] {
        // A type written as a value has what belongs to the type itself.
        if case .metatype(let instance) = type {
            return members(of: instance, named: name)
                .filter {
                    switch $0.kind {
                    case .method(let method): method.isStatic
                    case .property(let property): property.isStatic
                    case .initializer, .enumCase: true
                    default: false
                    }
                }
        }
        return withMainTask {
            guard var annotation = self.annotation(type) else { return [] }
            // A generic Swift type by its bare name has members whatever it holds: `Array`, `Set`.
            if case .named(let typeName) = annotation,
                let generic = Bridge.types[typeName]?.genericParameters,
                !generic.isEmpty
            {
                annotation = .generic(typeName, generic.map { _ in .unknown })
            }
            return memberSymbols(named: name, of: annotation)
        }
    }

    private func globalSymbols(named name: String?) -> [Symbol] {
        if let name {
            return lookup(name).map { symbols(of: name, binding: $0) } ?? []
        }
        // What was declared, then the core's builtins it doesn't shadow.
        let declared = scopes[1].bindings
        let core = scopes[0].bindings.filter { declared[$0.key] == nil }
        return (declared.sorted { $0.key < $1.key } + core.sorted { $0.key < $1.key })
            .flatMap { symbols(of: $0.key, binding: $0.value) }
    }

    private func symbols(of name: String, binding: Binding) -> [Symbol] {
        switch binding.value.storage {
        case .function(let callable):
            let candidates =
                (callable as? OverloadSet)?.candidates ?? (callable as? Function).map { [$0] } ?? []
            return candidates.map { symbol(of: $0, named: name) }
        case .object(let type as any DeclaredType): return [typeSymbol(named: name, type)]
        default:
            let checker = TypeChecker(interpreter: self)
            return [
                Symbol(
                    name: name,
                    kind: .variable(
                        Symbol.Variable(
                            type: scriptType(checker.type(of: binding.value)),
                            isSettable: binding.mutable
                        )
                    )
                )
            ]
        }
    }

    /// A declared type as a symbol.
    func typeSymbol(named name: String, _ type: any DeclaredType) -> Symbol {
        let kind: Symbol.Kind =
            switch type {
            case is StructType: .structure
            case is Value.EnumCase.Enumeration: .enumeration
            case let type as ClassType: type.isActor ? .actor : .class
            default: .protocol
            }
        var symbol = Symbol(name: name, kind: kind)
        symbol.id = type.id
        return symbol
    }

    /// What a function is, as a symbol: `name` when it has none of its own.
    func symbol(of function: Function, named name: String) -> Symbol {
        var symbol = Symbol(
            name: function.name ?? name,
            summary: function.documentation.map(\.summary)
                .flatMap { $0.isEmpty ? nil : $0 },
            kind: .function(
                Symbol.Function(
                    parameters: function.parameters.map {
                        parameter(
                            $0,
                            documentation: function.documentation?.parameters[$0.name]
                        )
                    },
                    returns: function.returnType.map(scriptType) ?? .void,
                    isThrowing: function.isThrowing,
                    isAsync: function.effect != .sync,
                    generics: function.generics
                )
            ),
            attributes: function.attributes
        )
        symbol.isBuiltin = function.isBuiltin
        return symbol
    }

    /// What a bridged Swift member is, as a symbol: a method is a function, anything else a variable.
    /// `bindings` says what the generic parameters of its type are.
    func bridgedSymbol(
        _ member: BridgedMember,
        checker: TypeChecker,
        bindings: [String: TypeAnnotation] = [:],
        isSettable: Bool = false
    ) -> Symbol {
        func function() -> Symbol.Function {
            Symbol.Function(
                parameters: member.parameters.map {
                    let substituted = checker.substitute($0.type, bindings)
                    var made = Symbol.Parameter(
                        label: $0.label,
                        name: $0.name,
                        type: scriptType(substituted),
                        arity: $0.variadic
                            ? .variadic
                            : $0.defaultValue != nil || $0.externalDefault != nil
                                ? .defaulted(.computed) : .required,
                        documentation: member.parameterDocs[$0.name]
                    )
                    made.annotation = substituted
                    return made
                },
                returns: scriptType(checker.substitute(member.returns, bindings)),
                isThrowing: member.isThrowing,
                isAsync: member.effect != .sync,
                generics: member.generics
            )
        }
        let kind: Symbol.Kind =
            switch member.kind {
            case .method:
                .method(
                    Symbol.Method(
                        function: function(),
                        isMutating: member.isMutating,
                        isStatic: member.isStatic
                    )
                )
            case .initializer: .initializer(function())
            default:
                .property(
                    Symbol.Property(
                        variable: Symbol.Variable(
                            type: scriptType(checker.substitute(member.returns, bindings)),
                            isSettable: isSettable
                        ),
                        isStatic: member.isStatic
                    )
                )
            }
        return Symbol(
            name: member.kind == .initializer ? "init" : member.name,
            summary: member.summary.isEmpty ? nil : member.summary,
            kind: kind,
            attributes: member.attributes
        )
    }

    fileprivate func parameter(
        _ parameter: Parameter,
        documentation: String? = nil
    ) -> Symbol.Parameter {
        var plain: Value?
        if case .literal(let value)? = parameter.defaultValue { plain = value }
        var made = Symbol.Parameter(
            label: parameter.label,
            name: parameter.name,
            type: scriptType(parameter.type),
            arity: parameter.variadic
                ? .variadic
                : parameter.defaultValue != nil || parameter.externalDefault != nil
                    ? .defaulted(plain.map { .value($0) } ?? .computed) : .required,
            documentation: documentation
        )
        made.annotation = parameter.type
        return made
    }

    /// What a type has, for `ScriptType.members(named:in:)`: its instance members, its static ones, its
    /// initializers, and the cases of an enum. `rawValues` says the raw values of enums not yet
    /// declared (as `check` reads them), by enum and case.
    func memberSymbols(
        named name: String?,
        of type: TypeAnnotation,
        checker: TypeChecker? = nil,
        rawValues: [String: [String: Value]] = [:]
    ) -> [Symbol] {
        let checker = checker ?? TypeChecker(interpreter: self)
        var found: [Symbol] = []
        func function(
            _ signature: TypeChecker.Signature,
            dropping receiver: Bool = false
        ) -> Symbol.Function {
            var parameters = signature.parameters
            if receiver, parameters.first?.name == "self" { parameters.removeFirst() }
            return Symbol.Function(
                parameters: parameters.map {
                    parameter($0, documentation: signature.documentation?.parameters[$0.name])
                },
                returns: scriptType(signature.returns),
                isThrowing: signature.isThrowing,
                isAsync: signature.effect != .sync,
                generics: signature.generics
            )
        }
        func add(
            _ signature: TypeChecker.Signature,
            dropping receiver: Bool = false,
            isStatic: Bool = false
        ) {
            found.append(
                Symbol(
                    name: signature.name,
                    summary: signature.documentation.map(\.summary)
                        .flatMap { $0.isEmpty ? nil : $0 },
                    kind: .method(
                        Symbol.Method(
                            function: function(signature, dropping: receiver),
                            isMutating: signature.isMutating,
                            isStatic: isStatic
                        )
                    ),
                    attributes: signature.attributes
                )
            )
        }
        // A struct's, enum's or host object's own.
        if let profile = checker.describe(type) {
            for (member, signatures) in profile.declared.methods where name == nil || name == member
            {
                signatures.forEach { add($0) }
            }
            for (member, signatures) in profile.extended.methods where name == nil || name == member
            {
                signatures.forEach { add($0) }
            }
            for (member, property) in profile.declared.properties
            where name == nil || name == member {
                found.append(
                    Symbol(
                        name: member,
                        kind: .property(
                            Symbol.Property(
                                variable: Symbol.Variable(
                                    type: scriptType(property.type),
                                    isSettable: property.isSettable
                                )
                            )
                        )
                    )
                )
            }
            // What belongs to the type itself.
            for set in [profile.declared, profile.extended] {
                for (member, signatures) in set.staticMethods where name == nil || name == member {
                    signatures.forEach { add($0, isStatic: true) }
                }
            }
            for (member, property) in profile.declared.staticProperties
            where name == nil || name == member {
                found.append(
                    Symbol(
                        name: member,
                        kind: .property(
                            Symbol.Property(
                                variable: Symbol.Variable(
                                    type: scriptType(property.type),
                                    isSettable: property.isSettable
                                ),
                                isStatic: true
                            )
                        )
                    )
                )
            }
            if name == nil || name == "init" {
                // A struct with none of its own is made by its memberwise one.
                var initializers = profile.declared.initializers
                if initializers.isEmpty, profile.kind == .structure,
                    let memberwise = profile.memberwise
                {
                    initializers = [memberwise]
                }
                for initializer in initializers {
                    found.append(
                        Symbol(
                            name: "init",
                            kind: .initializer(function(initializer)),
                            attributes: initializer.attributes
                        )
                    )
                }
            }
            if profile.kind == .enumeration {
                let runtime = enumType(named: profile.name)
                for enumCase in profile.cases where name == nil || name == enumCase.name {
                    let raw =
                        rawValues[profile.name]?[enumCase.name]
                        ?? runtime?.case(named: enumCase.name)?.rawValue
                    found.append(
                        Symbol(
                            name: enumCase.name,
                            kind: .enumCase(
                                parameters: enumCase.payload.enumerated()
                                    .map { index, value in
                                        Symbol.Parameter(
                                            label: value.label,
                                            name: value.label ?? String(index),
                                            type: scriptType(value.type)
                                        )
                                    },
                                rawValue: raw
                            )
                        )
                    )
                }
            }
        }
        // A bridged Swift type's.
        if let (bridgedType, bindings) = checker.bridged(type) {
            let settable = Set(
                bridgedType.members.filter { $0.kind == .setter && !$0.isStatic }.map(\.name)
            )
            for member in bridgedType.members
            where member.kind != .setter && (name == nil || name == member.name) {
                found.append(
                    bridgedSymbol(
                        member,
                        checker: checker,
                        bindings: bindings,
                        isSettable: settable.contains(member.name)
                    )
                )
            }
        }
        // What every sequence has: what the host's prelude adds to `Sequence`, which
        // `ScriptType.named(.sequence).members(in:)` lists alone.
        var holder: TypeAnnotation?
        if case .list(let element) = type {
            holder = element
        } else if case .named("Sequence") = type {
            holder = .unknown
        }
        if let element = holder {
            for (member, set) in sequenceMethods where name == nil || name == member {
                for signature in checker.sequenceSignatures(set) {
                    var made = signature
                    made.parameters = made.parameters.map {
                        var p = $0; p.type = checker.substitute(p.type, ["Element": element]);
                        return p
                    }
                    made.returns = checker.substitute(made.returns, ["Element": element])
                    add(made, dropping: true)
                }
            }
        }
        return found
    }

    /// How to color Swift source, in characters, which may be half typed: what it reads before a
    /// problem is colored as it reads it.
    public func highlighting(_ source: String) -> [Highlight] {
        let bound = withMainTask { globalNames() }
        return frontEnd.highlight(source, bound: bound)
            .map { span in
                let kind: Highlight.Kind =
                    switch span.kind {
                    case .keyword: .keyword
                    case .function: .function
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
        public enum Kind: Sendable {
            case keyword, function, string, number, constant, variable, comment, type, punctuation
        }
        public var range: Range<Int>
        public var kind: Kind
    }

    func typeID(named name: String) -> Symbol.ID? {
        (globals(named: name) + types.filter { $0.name == name }).lazy.compactMap(\.id).first
    }

    func symbol(for id: Symbol.ID) -> Symbol? {
        withMainTask {
            switch id.kind {
            case .declared:
                declaredTypes[id].map { typeSymbol(named: id.name, $0) }
            case .host:
                types.first { $0.id == id }
            case .parameter:
                nil
            }
        }
    }

    /// Whether `id` still means what it did: a declared ID whose declaration is no longer the one
    /// its name means (another `struct Point` was declared since) has gone stale, and a type
    /// written with it is not the type its name means now.
    func isCurrent(_ id: Symbol.ID) -> Bool {
        guard case .declared = id.kind else { return true }
        guard case .object(let object)? = lookup(id.name)?.value.storage else { return false }
        return (object as? any DeclaredType)?.id == id
    }

    /// A type as the checker reads it, or nil when it names a declared type that has gone stale.
    func annotation(_ type: ScriptType) -> TypeAnnotation? {
        func current(_ type: ScriptType) -> Bool {
            switch type {
            case .named(let id, let arguments): isCurrent(id) && arguments.allSatisfy(current)
            case .function(let parameters, let returns, _, _):
                parameters.allSatisfy(current) && current(returns)
            case .tuple(let elements): elements.allSatisfy { current($0.type) }
            case .metatype(let type): current(type)
            }
        }
        return current(type) ? TypeAnnotation(type) : nil
    }

    /// Every type a script can name, its members to be had from `ScriptType.members(named:in:)`: those scripts and
    /// the host declare, and Swift's own that the core bridges (`String`, `Array`, `Date`).
    public var types: [Symbol] {
        withMainTask {
            let declared = scopes[1].bindings.sorted { $0.key < $1.key }
                .flatMap { symbols(of: $0.key, binding: $0.value) }
                .filter {
                    if $0.isType { true } else { false }
                }
            let bridged = scopes[0].bindings.sorted { $0.key < $1.key }
                .compactMap { name, binding -> Symbol? in
                    if case .object(is BridgedTypeName) = binding.value.storage {
                        var symbol = Symbol(name: name, kind: .structure)
                        symbol.id = .host(name)
                        symbol.isBuiltin = true
                        return symbol
                    } else {
                        return nil
                    }
                }
            return declared + bridged
        }
    }

    func conforms(_ type: ScriptType, to proto: Symbol.ID) -> Bool {
        inCurrentTask {
            guard isCurrent(proto), let annotation = annotation(type) else { return false }
            return TypeChecker(interpreter: self).conforms(annotation, to: proto.name)
        }
    }

    func overload(
        among candidates: [Symbol],
        arguments: [ScriptType.Element]
    ) throws(Diagnostic) -> Symbol {
        guard !candidates.isEmpty else {
            throw Diagnostic(kind: .type, message: "there is nothing to call")
        }
        let checker = TypeChecker(interpreter: self)
        func penalty(_ candidate: Symbol) -> Int? {
            guard let parameters = candidate.function?.parameters else { return nil }
            var cost = 0
            var next = 0
            var given: Set<String> = []
            for argument in arguments {
                // The parameter this argument is for: by label, else the next without one.
                guard
                    let index = parameters[next...]
                        .firstIndex(where: { $0.label == argument.label })
                        ?? parameters.firstIndex(where: {
                            $0.arity == .variadic && $0.label == argument.label
                        })
                else { return nil }
                let parameter = parameters[index]
                // A function of a signature not known fits where any function is wanted.
                guard var actual = annotation(argument.type),
                    let expected = parameter.annotation ?? annotation(parameter.type)
                else { return nil }
                if actual == .function { actual = .unknown }
                guard checker.fits(actual, expected) else { return nil }
                if expected == .any || expected == .unknown { cost += 1 }
                given.insert(parameter.name)
                next = parameter.arity == .variadic ? index : index + 1
            }
            // What is left out must have a default.
            for parameter in parameters
            where !given.contains(parameter.name) && parameter.arity == .required { return nil }
            return cost
        }
        let fitting = candidates.compactMap { candidate in
            penalty(candidate).map { (candidate, $0) }
        }
        guard let best = fitting.map(\.1).min() else {
            let shown = arguments.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }
                .joined(separator: ", ")
            throw Diagnostic(
                kind: .type,
                message: "\(candidates[0].name): no overload accepts (\(shown))"
            )
        }
        let winners = fitting.filter { $0.1 == best }
        guard winners.count == 1 else {
            throw Diagnostic(
                kind: .type,
                message: "\(candidates[0].name): ambiguous call; \(winners.count) overloads match"
            )
        }
        return winners[0].0
    }

    /// Checks a program as `evaluate` would, and stops there: nothing runs, so a mistake is found
    /// before any statement's effect happens. It says what the program declares at its top level
    /// (its functions, types and variables), which a host can check its own uses against.
    public func check(_ source: String) throws(Diagnostic) -> Declarations {
        do {
            return try inCurrentTask { () throws -> Declarations in
                switch parse(source) {
                case .failure(let error):
                    throw Diagnostic(
                        kind: .syntax(isIncomplete: error.incomplete),
                        message: error.description,
                        range: error.range
                    )
                case .success(let program):
                    let checker = TypeChecker(interpreter: self)
                    do {
                        _ = try checker.check(program)
                    } catch let error as TypeError {
                        throw Diagnostic(
                            kind: .type,
                            message: error.message,
                            range: error.spot ?? error.range
                                ?? error.line.map { SourceRange(line: $0) }
                        )
                    }
                    // The doc comments of the functions it declares, in the order it declares them.
                    var docs: [String: [Documentation]] = [:]
                    for case .function(let decl) in program.statements {
                        docs[decl.name, default: []]
                            .append(
                                decl.documentation ?? Documentation(summary: "", parameters: [:])
                            )
                    }
                    var declarations = Declarations(
                        symbols: checker.scopes[0].sorted { $0.key < $1.key }
                            .flatMap { declaredSymbols(of: $0.key, $0.value) }
                            .map { symbol in
                                guard case .function(var function) = symbol.kind,
                                    var queue = docs[symbol.name],
                                    !queue.isEmpty
                                else { return symbol }
                                let documentation = queue.removeFirst()
                                docs[symbol.name] = queue
                                var documented = symbol
                                documented.summary =
                                    documentation.summary.isEmpty ? nil : documentation.summary
                                function.parameters = function.parameters.map {
                                    var p = $0; p.documentation = documentation.parameters[p.name];
                                    return p
                                }
                                documented.kind = .function(function)
                                return documented
                            }
                    )
                    // What each type it declares has, which does not exist to ask yet: an enum's
                    // cases, with the raw values it writes or Swift gives them.
                    var rawValues: [String: [String: Value]] = [:]
                    for case .enumDecl(let decl) in program.statements {
                        rawValues[decl.name] = Interpreter.rawValues(of: decl)
                    }
                    for (name, symbol) in checker.scopes[0] {
                        switch symbol {
                        case .structType, .enumType:
                            declarations.members[name] = memberSymbols(
                                named: nil,
                                of: .named(name),
                                checker: checker,
                                rawValues: rawValues
                            )
                        default: break
                        }
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
        /// What each struct and enum it declares has, by the type's name: its members, its
        /// initializers and an enum's cases, for reading a word against an enum before it exists.
        public var members: [String: [Symbol]] = [:]
    }

    /// The raw values an enum's cases have: the ones written as literals, and the ones Swift gives
    /// the rest (`0, 1, 2…` for an `Int`, the case's name for a `String`).
    static func rawValues(of decl: EnumDecl) -> [String: Value] {
        guard let rawType = decl.rawType else { return [:] }
        var values: [String: Value] = [:]
        var next = 0
        for enumCase in decl.cases {
            var raw: Value?
            if case .literal(let value)? = enumCase.rawValue {
                raw = value
            } else if enumCase.rawValue == nil {
                switch rawType {
                case .int: raw = .int(next)
                case .string: raw = .string(enumCase.name)
                default: break
                }
            }
            if let raw {
                values[enumCase.name] = raw
                if case .int(let n) = raw.storage { next = n + 1 }
            }
        }
        return values
    }

    private func declaredSymbols(of name: String, _ symbol: TypeChecker.Symbol) -> [Symbol] {
        switch symbol {
        case .functions(let signatures):
            return signatures.map { signature in
                Symbol(
                    name: signature.name,
                    kind: .function(
                        Symbol.Function(
                            parameters: signature.parameters.map { parameter($0) },
                            returns: scriptType(signature.returns),
                            isThrowing: signature.isThrowing,
                            isAsync: signature.effect != .sync
                        )
                    )
                )
            }
        case .structType: return [Symbol(name: name, kind: .structure)]
        case .enumType: return [Symbol(name: name, kind: .enumeration)]
        case .protocolType: return [Symbol(name: name, kind: .protocol)]
        case .variable(let type, let mutable):
            return [
                Symbol(
                    name: name,
                    kind: .variable(
                        Symbol.Variable(type: ScriptType(type), isSettable: mutable)
                    )
                )
            ]
        case .swiftType, .asyncLet: return []
        }
    }

    /// The type of an expression written at the top level: the globals are in scope, a script's
    /// locals are not.
    public func scriptType(ofExpression expression: String) throws(Diagnostic) -> ScriptType {
        do {
            return try withMainTask { () throws -> ScriptType in
                switch parse(expression) {
                case .failure(let error):
                    throw Diagnostic(
                        kind: .syntax(isIncomplete: error.incomplete),
                        message: error.description,
                        range: error.range
                    )
                case .success(let program):
                    guard program.statements.count == 1,
                        case .expression(var expr) = program.statements[0]
                    else {
                        throw Diagnostic(
                            kind: .type,
                            message: "scriptType(of:) takes one expression"
                        )
                    }
                    do {
                        return scriptType(try TypeChecker(interpreter: self).typeOf(&expr))
                    } catch let error as TypeError {
                        throw Diagnostic(
                            kind: .type,
                            message: error.message,
                            range: error.spot ?? error.range
                                ?? error.line.map { SourceRange(line: $0) }
                        )
                    }
                }
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }
}

// MARK: Looking up what a type is and has

extension Symbol.ID {
    /// The ID of the type a script can name `name`: one it or the host declares, or one of Swift's
    /// the core bridges. Nil when there is none. A host asks once, after loading the source that
    /// declares the type, and keeps the answer.
    public init?(named name: String, in interpreter: Interpreter) {
        guard let id = interpreter.typeID(named: name) else { return nil }
        self = id
    }

    /// What the ID names: a script's declaration (even one a later declaration of the same name
    /// hides), or a type the host registers or the core bridges. Nil for an ID that names nothing:
    /// a Swift type that is not registered (an encoded value's), a declared type of another
    /// interpreter, a generic parameter.
    public func symbol(in interpreter: Interpreter) -> Symbol? {
        interpreter.symbol(for: self)
    }
}

extension ScriptType {
    /// What the type has: the methods and properties of its values (a struct's, a host object's, a
    /// bridged type's, the sequence methods of a list), and what belongs to the type itself, marked
    /// `isStatic`: its static members, its initializers and the cases of an enum. Only those
    /// called `name`, if one is given. `ScriptType(Int.self).members(in: interpreter)` is what a
    /// Swift type has for scripts.
    public func members(named name: String? = nil, in interpreter: Interpreter) -> [Symbol] {
        interpreter.members(of: self, named: name)
    }
}

extension Sequence where Element == Symbol {
    /// Which of these functions a call with these arguments means: by their labels and types, the
    /// one that fits with the fewest conversions. Throws the checker's own complaint when none fits
    /// or several do.
    public func overload(
        arguments: [ScriptType.Element],
        in interpreter: Interpreter
    ) throws(Diagnostic) -> Symbol {
        try interpreter.overload(among: Array(self), arguments: arguments)
    }
}
