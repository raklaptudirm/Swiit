import SwiftSyntax
import SwiitKit

extension Lowering {
    // MARK: Declarations

    mutating func declaration(_ decl: DeclSyntax) throws -> [Statement] {
        if let node = decl.as(VariableDeclSyntax.self) { return try variables(node) }
        if let node = decl.as(FunctionDeclSyntax.self) {
            functions.insert(node.name.text)
            bind(node.name.text)
            return [.function(try function(node))]
        }
        if let node = decl.as(ProtocolDeclSyntax.self) { return [.protocolDecl(try protocolDeclaration(node))] }
        // `infix operator **`, `precedencegroup Power { … }`: kept, for later programs to fold by.
        if let node = decl.as(OperatorDeclSyntax.self) {
            return [.operatorDeclaration(key: "operator \(node.name.text)", source: node.trimmedDescription)]
        }
        if let node = decl.as(PrecedenceGroupDeclSyntax.self) {
            return [.operatorDeclaration(key: "precedencegroup \(node.name.text)", source: node.trimmedDescription)]
        }
        if let node = decl.as(StructDeclSyntax.self) {
            let lowered = try structure(node)
            return takeNested() + [.structDecl(lowered)]
        }
        if let node = decl.as(EnumDeclSyntax.self) {
            let lowered = try enumeration(node)
            return takeNested() + [.enumDecl(lowered)]
        }
        if let node = decl.as(ClassDeclSyntax.self) {
            let lowered = try classDeclaration(node.name.text, node.genericParameterClause, node.genericWhereClause, node.inheritanceClause,
                                               node.memberBlock, isActor: false, node: node)
            return takeNested() + [.classDecl(lowered)]
        }
        if let node = decl.as(ActorDeclSyntax.self) {
            let lowered = try classDeclaration(node.name.text, node.genericParameterClause, node.genericWhereClause, node.inheritanceClause,
                                               node.memberBlock, isActor: true, node: node)
            return takeNested() + [.classDecl(lowered)]
        }
        if prelude, let node = decl.as(ExtensionDeclSyntax.self) { return [try sequenceExtension(node)] }
        if let node = decl.as(ExtensionDeclSyntax.self) { return try typeExtension(node) }
        if let node = decl.as(ImportDeclSyntax.self) { return try importDeclaration(node) }
        if let node = decl.as(IfConfigDeclSyntax.self) { return try conditional(node) }
        if let node = decl.as(TypeAliasDeclSyntax.self) {
            guard node.genericParameterClause == nil else { throw unsupported("a generic typealias", node) }
            aliases[node.name.text] = try type(node.initializer.value)
            return []
        }
        throw unsupported("'\(decl.kind)'", decl)
    }

    /// `import Foundation`: what the interpreter already has, so nothing to do.
    /// Any other module isn't there to import yet.
    private func importDeclaration(_ node: ImportDeclSyntax) throws -> [Statement] {
        guard node.importKindSpecifier == nil, let module = node.path.first, node.path.count == 1 else {
            throw unsupported("this import", node)
        }
        guard Lowering.modules.contains(module.name.text) else {
            throw SyntaxError("no such module '\(module.name.text)'; Swiit has \(Lowering.modules.sorted().joined(separator: ", ")) (line \(line(of: node)))")
        }
        return []
    }

    /// The modules whose declarations are always there.
    /// Swift's other integer types, which Swiit reads as Int.
    static let fixedWidthIntegers: Set<String> = ["Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64"]
    /// Types Swift's standard library spells two ways: the old name, and the type it is.
    static let swiftAliases = ["UnicodeScalar": "Unicode.Scalar"]
    static let modules: Set<String> = ["Swift", "Foundation", "SystemPackage", "SwiitKit", "_StringProcessing"]

    private mutating func variables(_ node: VariableDeclSyntax) throws -> [Statement] {
        // `async let x = f()`: `f()` starts as a task the scope owns.
        // Who may see it (`private var x`) matters to no one in a program that is one file.
        let access: Set<Keyword> = [.private, .fileprivate, .internal, .public, .open, .package]
        let modifiers = node.modifiers.filter { modifier in
            if case .keyword(let keyword) = modifier.name.tokenKind { return !access.contains(keyword) }
            return true
        }
        let isAsync = modifiers.count == 1 && modifiers.first?.name.tokenKind == .keyword(.async)
            && node.bindingSpecifier.tokenKind == .keyword(.let)
        // `weak var x: T?`: it holds its instance without keeping it alive.
        let isWeak = modifiers.count == 1 && (modifiers.first?.name.tokenKind == .keyword(.weak) || modifiers.first?.name.tokenKind == .keyword(.unowned))
        guard node.attributes.isEmpty, modifiers.isEmpty || isAsync || isWeak else { throw unsupported("a modifier on a variable", node) }
        let mutable = node.bindingSpecifier.tokenKind == .keyword(.var)
        var statements: [Statement] = []
        for binding in node.bindings {
            // `let _ = f()`: the value, thrown away.
            // `let (a, b) = pair`: the pair held once, and each name from it.
            if let tuple = binding.pattern.as(TuplePatternSyntax.self) {
                guard !isAsync, binding.accessorBlock == nil, let initializer = binding.initializer else {
                    throw unsupported("this variable", binding)
                }
                var value = try expression(initializer.value)
                if let annotation = binding.typeAnnotation { value = .annotated(value, try type(annotation.type)) }
                let pattern = try self.pattern(PatternSyntax(tuple), mutable: mutable)
                destructurings += 1
                let held = InternalName.tuple(destructurings)
                statements.append(.declare(name: held, mutable: false, value: value))
                statements += Lowering.destructure(pattern, of: .variable(held))
                continue
            }
            let name: String
            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                name = identifier.identifier.text
            } else if binding.pattern.is(WildcardPatternSyntax.self) {
                name = "_"
            } else {
                throw unsupported("this variable", binding)
            }
            if binding.accessorBlock != nil {
                guard !isAsync, !isWeak, name != "_", binding.typeAnnotation != nil || binding.initializer != nil else {
                    throw unsupported("this variable", binding)
                }
                statements += try computedVariable(name, type: try binding.typeAnnotation.map { try type($0.type) } ?? .any, binding)
                continue
            }
            // `var x: Int?` starts as nil; `let y: Int` is given its value later.
            guard let initializer = binding.initializer else {
                guard let annotation = binding.typeAnnotation, !isAsync else { throw unsupported("a variable without a value", binding) }
                let written = try type(annotation.type)
                if isWeak {
                    if name != "_" { bind(name) }
                    statements.append(.declare(name: name, mutable: true, value: .call(.variable(InternalName.weak), [Argument(value: .annotated(.literal(.nothing), { if case .optional = written { written } else { .optional(written) } }()))])))
                } else if case .optional = written {
                    if name != "_" { bind(name) }
                    statements.append(.declare(name: name, mutable: true, value: .annotated(.literal(.nothing), written)))
                } else {
                    if name != "_" { bind(name) }
                    statements.append(.declare(name: name, mutable: true, value: .call(.variable(InternalName.uninitialized), [])))
                }
                continue
            }
            var value = try expression(initializer.value)
            if isAsync {
                let operation = ClosureLiteral(
                    parameters: [], returnType: try binding.typeAnnotation.map { try type($0.type) },
                    body: Program(statements: [.expression(value)], lines: [line(of: initializer.value)]),
                    names: NamesUsed(names: names(in: initializer.value))
                )
                value = .childTask(operation)
            } else if let annotation = binding.typeAnnotation {
                value = .annotated(value, try type(annotation.type))
            }
            if isWeak { value = .call(.variable(InternalName.weak), [Argument(value: value)]) }
            if name != "_" { bind(name) }
            statements.append(.declare(name: name, mutable: mutable, value: value))
        }
        return statements
    }

    /// `var total: Int { get { … } set { … } }` outside a type: a getter function, and a setter if there is one,
    /// which a read and an assignment of the name call.
    private mutating func computedVariable(_ name: String, type: TypeAnnotation, _ binding: PatternBindingSyntax) throws -> [Statement] {
        guard let accessors = binding.accessorBlock else { return [] }
        var getter: CodeBlockItemListSyntax?
        var setter: CodeBlockItemListSyntax?
        var willSet: CodeBlockItemListSyntax?, didSet: CodeBlockItemListSyntax?
        var newValue = "newValue", willSetName = "newValue", oldValue = "oldValue"
        switch accessors.accessors {
        case .getter(let body): getter = body
        case .accessors(let list):
            for accessor in list {
                guard let body = accessor.body?.statements else { throw unsupported("an accessor without a body", accessor) }
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.get): getter = body
                case .keyword(.set): setter = body; newValue = accessor.parameters?.name.text ?? "newValue"
                case .keyword(.willSet): willSet = body; willSetName = accessor.parameters?.name.text ?? "newValue"
                case .keyword(.didSet): didSet = body; oldValue = accessor.parameters?.name.text ?? "oldValue"
                default: throw unsupported("this accessor on a variable", accessor)
                }
            }
        }
        facts.computedGlobals.insert(name)
        // `var x: T? { didSet { … } }`: a variable of its own, set through a function that runs the observers.
        if getter == nil, willSet != nil || didSet != nil {
            let held = InternalName.stored(name)
            var statements: [Statement] = []
            let start: Expr
            if let initializer = binding.initializer {
                start = type == .any ? try expression(initializer.value) : .annotated(try expression(initializer.value), type)
            }
            else if case .optional = type { start = .annotated(.literal(.nothing), type) }
            else { throw unsupported("a variable with observers and no value", binding) }
            statements.append(.declare(name: held, mutable: true, value: start))
            let reading = Program(statements: [.returnStatement(.variable(held))])
            statements.append(.function(FunctionDecl(name: InternalName.getter(name), parameters: [], returnType: type == .any ? .unknown : type, body: reading)))
            func lowered(_ body: CodeBlockItemListSyntax, parameters: [String]) throws -> [Statement] {
                locals.append(Set(parameters))
                let outer = leaving
                leaving = Leaving(function: leaving.function + 1)
                defer { locals.removeLast(); leaving = outer }
                return try block(body, scoped: false).statements
            }
            var body: [Statement] = []
            if let willSet { body += try lowered(willSet, parameters: [willSetName]).map { $0 } }
            if didSet != nil { body.append(.declare(name: oldValue, mutable: false, value: .variable(held))) }
            body.append(.assign(Assignment(root: held, path: [], op: nil, value: .variable(willSet != nil ? willSetName : "newValue"))))
            if let didSet { body += try lowered(didSet, parameters: [oldValue]) }
            let parameter = Parameter(label: nil, name: willSet != nil ? willSetName : "newValue", type: type == .any ? .unknown : type)
            statements.append(.function(FunctionDecl(
                name: InternalName.setter(name), parameters: [parameter], returnType: nil, body: Program(statements: body),
                names: NamesUsed(names: (willSet.map { names(in: $0) } ?? []).union(didSet.map { names(in: $0) } ?? []))
            )))
            return statements
        }
        guard let getter else { throw unsupported("a variable without a getter", binding) }
        func lowered(_ body: CodeBlockItemListSyntax, parameters: [Parameter]) throws -> Program {
            locals.append(Set(parameters.map(\.name)))
            let outer = leaving
            leaving = Leaving(function: leaving.function + 1)
            defer { locals.removeLast(); leaving = outer }
            return try block(body, scoped: false)
        }
        var statements = [Statement.function(FunctionDecl(
            name: InternalName.getter(name), parameters: [], returnType: type, body: try lowered(getter, parameters: []),
            names: NamesUsed(names: names(in: getter))
        ))]
        if let setter {
            let parameter = Parameter(label: nil, name: newValue, type: type)
            statements.append(.function(FunctionDecl(
                name: InternalName.setter(name), parameters: [parameter], returnType: nil, body: try lowered(setter, parameters: [parameter]),
                names: NamesUsed(names: names(in: setter))
            )))
        }
        return statements
    }

    /// The declarations that give each name in a tuple pattern its element of `value`.
    static func destructure(_ pattern: Pattern, of value: Expr) -> [Statement] {
        switch pattern {
        case .binding(let name, let mutable): [.declare(name: name, mutable: mutable, value: value)]
        case .tuple(let patterns):
            patterns.enumerated().flatMap { destructure($1, of: .member(value, "\($0)")) }
        default: []
        }
    }

    // MARK: Functions

    mutating func parameters(_ clause: FunctionParameterClauseSyntax) throws -> [Parameter] {
        let parameters = try lowerParameters(clause)
        try validate(parameters, in: clause)
        return parameters
    }

    /// What a signature can't say, as the layer's attributes make it: which parameter is
    /// the piped input, and which short flags there are. As in Swift, what follows
    /// a variadic needs a label, so it's clear where the variadic ends.
    private func validate(_ parameters: [Parameter], in node: some SyntaxProtocol) throws {
        var seen: Set<String> = []
        var shortFlags: Set<Character> = []
        if parameters.filter(\.isInput).count > 1 { throw SyntaxError("only one parameter can be @input (line \(line(of: node)))") }
        for (index, parameter) in parameters.enumerated() {
            if parameter.isInput && parameter.variadic {
                throw SyntaxError("an @input parameter can't be variadic; use a list type for the whole stream (line \(line(of: node)))")
            }
            if let flag = parameter.shortFlag {
                guard parameter.label != nil else { throw SyntaxError("@flag needs a labeled parameter (line \(line(of: node)))") }
                guard shortFlags.insert(flag).inserted else { throw SyntaxError("duplicate short flag -\(flag) (line \(line(of: node)))") }
            }
            if parameter.name != "_" && !seen.insert(parameter.name).inserted {
                throw SyntaxError("duplicate parameter '\(parameter.name)' (line \(line(of: node)))")
            }
            if parameter.variadic && index + 1 < parameters.count && parameters[index + 1].label == nil {
                throw SyntaxError("the parameter after a variadic needs a label (line \(line(of: node)))")
            }
            if parameter.variadic && parameter.defaultValue != nil {
                throw SyntaxError("a variadic parameter can't have a default value (line \(line(of: node)))")
            }
        }
    }

    private mutating func lowerParameters(_ clause: FunctionParameterClauseSyntax) throws -> [Parameter] {
        try clause.parameters.map { parameter in
            var shortFlag: Character?
            var isInput = false
            var resultBuilder: String?
            // `inout Int`: a specifier before the type.
            let isInout = parameter.type.as(AttributedTypeSyntax.self)?.specifiers.contains { specifier in
                if case .simpleTypeSpecifier(let simple) = specifier { return simple.specifier.tokenKind == .keyword(.inout) }
                return false
            } ?? false
            let isAutoclosure = parameter.type.as(AttributedTypeSyntax.self)?.attributes.contains { attribute in
                if case .attribute(let attribute) = attribute { return attribute.attributeName.trimmedDescription == "autoclosure" }
                return false
            } ?? false
            for attribute in parameter.attributes {
                guard case .attribute(let attribute) = attribute else { throw unsupported("this attribute", parameter) }
                switch attribute.attributeName.trimmedDescription {
                case "flag", "Flag":
                    guard case .argumentList(let arguments)? = attribute.arguments, arguments.count == 1,
                          let literal = arguments.first?.expression.as(StringLiteralExprSyntax.self),
                          let flag = literal.representedLiteralValue, flag.count == 1, let character = flag.first,
                          character.isLetter || character.isNumber else {
                        throw SyntaxError("@flag needs a single letter or digit, like @flag(\"n\") (line \(line(of: attribute)))")
                    }
                    shortFlag = character
                case "input", "Input":
                    isInput = true
                case let name where facts.resultBuilders.contains(name):
                    resultBuilder = name
                default:
                    throw SyntaxError("unknown attribute '@\(attribute.attributeName.trimmedDescription)' (line \(line(of: attribute)))")
                }
            }
            let first = parameter.firstName.text
            let name = parameter.secondName?.text ?? first
            var type = TypeAnnotation.any
            var variadic = false
            if let written = Optional(parameter.type) {
                type = try self.type(written)
                if parameter.ellipsis != nil { variadic = true }
            }
            let defaultValue = try parameter.defaultValue.map { try expression($0.value) }
            return Parameter(
                label: first == "_" ? nil : first, name: name, type: type, variadic: variadic, defaultValue: defaultValue,
                isInput: isInput, shortFlag: shortFlag, isInout: isInout, isAutoclosure: isAutoclosure
            ).withBuilder(resultBuilder)
        }
    }

    /// `<T, U: Comparable>` and `where T: Equatable`: each type parameter, and the protocols
    /// it has to conform to. Anything else a `where` says (same-type requirements) is left unchecked.
    func genericParameters(_ clause: GenericParameterClauseSyntax?, where whereClause: GenericWhereClauseSyntax? = nil) -> [String: [String]] {
        var generics: [String: [String]] = [:]
        for parameter in clause?.parameters ?? [] {
            generics[parameter.name.text, default: []] += parameter.inheritedType.map { [$0.trimmedDescription] } ?? []
        }
        for requirement in whereClause?.requirements ?? [] {
            guard case .conformanceRequirement(let conformance) = requirement.requirement,
                  let left = conformance.leftType.as(IdentifierTypeSyntax.self), generics[left.name.text] != nil else { continue }
            generics[left.name.text, default: []].append(conformance.rightType.trimmedDescription)
        }
        return generics
    }

    mutating func function(_ node: FunctionDeclSyntax, isMember: Bool = false) throws -> FunctionDecl {
        // The type parameters, which its signature and body name.
        let generics = genericParameters(node.genericParameterClause, where: node.genericWhereClause)
        let outerParameters = typeParameters
        typeParameters.formUnion(generics.keys)
        defer { typeParameters = outerParameters }
        let effects = node.signature.effectSpecifiers
        var parameters = try parameters(node.signature.parameterClause)
        // An operator's operands have no labels: its parameters' names are only for its body.
        if let first = node.name.text.first, !(first.isLetter || first == "_") {
            for index in parameters.indices { parameters[index].label = nil }
        }
        let returnType = try node.signature.returnClause.map { try type($0.type) }
        let mutating = node.modifiers.contains { $0.name.tokenKind == .keyword(.mutating) }
        // A prefix or postfix operator is told from the infix one of the same spelling by its name.
        var name = node.name.text
        if node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.prefix) }) { name = "prefix " + name }
        else if node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.postfix) }) { name = "postfix " + name }
        var thrownType = try effects?.throwsClause?.type.map { try type($0) }
        // `throws(Never)` throws nothing.
        if thrownType == .named("Never") { thrownType = nil }
        let isThrowing = effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.throws)
            && !(effects?.throwsClause?.type != nil && thrownType == nil)
        let isRethrowing = effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.rethrows)
        // In the prelude, a builtin's body is in Swift.
        guard let body = node.body else {
            guard prelude else { throw unsupported("a function without a body", node) }
            return FunctionDecl(
                name: name, parameters: parameters, returnType: returnType, body: Program(statements: []),
                documentation: documentation(of: node), isMutating: mutating, isThrowing: isThrowing,
                isAsync: effects?.asyncSpecifier != nil, isRethrowing: isRethrowing
            )
        }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        anonymous.append(false)
        functionNames.append(name + "(" + parameters.map { ($0.label ?? "_") + ":" }.joined() + ")")
        defer { locals.removeLast(); (tryDepth, leaving) = outer; anonymous.removeLast(); functionNames.removeLast() }
        let program = try block(body.statements, scoped: false)
        return FunctionDecl(
            name: name, parameters: parameters, returnType: returnType, body: program,
            documentation: documentation(of: node),
            isMutating: mutating, isThrowing: isThrowing, isAsync: effects?.asyncSpecifier != nil, isRethrowing: isRethrowing,
            generics: generics, names: NamesUsed(names: names(in: body))
        ).withBuilder(node.attributes.compactMap { attribute -> String? in
            guard case .attribute(let named) = attribute else { return nil }
            let name = named.attributeName.trimmedDescription
            return facts.resultBuilders.contains(name) ? name : nil
        }.first).withThrown(thrownType).withModifiers(
            override: node.modifiers.contains { $0.name.tokenKind == .keyword(.override) },
            nonisolated: node.modifiers.contains { $0.name.tokenKind == .keyword(.nonisolated) }
        )
    }

    private mutating func initializer(_ node: InitializerDeclSyntax) throws -> FunctionDecl {
        guard node.optionalMark?.tokenKind != .exclamationMark else { throw unsupported("this initializer", node) }
        let outerParameters = typeParameters
        typeParameters.formUnion(genericParameters(node.genericParameterClause, where: node.genericWhereClause).keys)
        defer { typeParameters = outerParameters }
        let parameters = try parameters(node.signature.parameterClause)
        guard let body = node.body else { throw unsupported("an initializer without a body", node) }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        anonymous.append(false)
        defer { locals.removeLast(); (tryDepth, leaving) = outer; anonymous.removeLast() }
        let program = try block(body.statements, scoped: false)
        var declaration = FunctionDecl(
            name: "init", parameters: parameters, body: program, documentation: documentation(of: node),
            isMutating: true, names: NamesUsed(names: names(in: body))
        )
        declaration.isFailable = node.optionalMark != nil
        declaration.isConvenience = node.modifiers.contains { $0.name.tokenKind == .keyword(.convenience) }
        declaration.isOverride = node.modifiers.contains { $0.name.tokenKind == .keyword(.override) }
        declaration.isNonisolated = node.modifiers.contains { $0.name.tokenKind == .keyword(.nonisolated) }
        return declaration
    }

    /// `extension Sequence { func select(…) -> … }`, in the prelude: the methods
    /// every sequence has, with its items' type as `Element`.
    private mutating func sequenceExtension(_ node: ExtensionDeclSyntax) throws -> Statement {
        guard node.extendedType.trimmedDescription == "Sequence" else { throw SyntaxError("only Sequence can be extended, for now") }
        guard node.genericWhereClause == nil, node.inheritanceClause == nil else { throw unsupported("this extension", node) }
        var methods: [FunctionDecl] = []
        for member in node.memberBlock.members {
            guard let method = member.decl.as(FunctionDeclSyntax.self) else { throw unsupported("'\(member.decl.kind)' in an extension", member) }
            var lowered = try function(method, isMember: true)
            lowered.generics["Element", default: []] += []
            methods.append(lowered)
        }
        return .extensionDecl(name: "Sequence", methods: methods)
    }

    // MARK: Structs

    /// The names a type's methods may use unqualified: its instance members,
    /// read through `self`, and its static ones.
    func memberNames(of block: MemberBlockSyntax) -> (instance: Set<String>, static: Set<String>) {
        var instance: Set<String> = []
        var statics: Set<String> = []
        for member in block.members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    if isStatic(variable.modifiers) { statics.insert(identifier.identifier.text) } else { instance.insert(identifier.identifier.text) }
                }
            }
            if let method = member.decl.as(FunctionDeclSyntax.self) {
                if isStatic(method.modifiers) { statics.insert(method.name.text) } else { instance.insert(method.name.text) }
            }
        }
        return (instance, statics)
    }

    /// `class Dog: Animal { … }`, `actor Counter { … }`.
    private mutating func classDeclaration(
        _ written: String, _ generics: GenericParameterClauseSyntax?, _ whereClause: GenericWhereClauseSyntax?,
        _ inheritance: InheritanceClauseSyntax?, _ block: MemberBlockSyntax, isActor: Bool, node: some SyntaxProtocol
    ) throws -> ClassDecl {
        let outerParameters = typeParameters
        typeParameters.formUnion(genericParameters(generics, where: whereClause).keys)
        defer { typeParameters = outerParameters }
        // `Base<String>` is Base: its arguments only say what it holds.
        let inherited = inheritance?.inheritedTypes.map { inheritedType -> String in
            let text = inheritedType.type.trimmedDescription
            return text.firstIndex(of: "<").map { String(text[..<$0]) } ?? text
        } ?? []
        try checkProtocols(inherited)
        let qualified = typePrefix + written
        var members = StructDecl(name: qualified, properties: [], methods: [], initializers: [], conformances: [])
        var declaration = ClassDecl(name: qualified, inherited: inherited, members: members, deinitializer: nil, isActor: isActor)
        var (instanceMembers, staticMembers) = memberNames(of: block)
        // What it inherits from the classes above, which its bodies name as their own.
        var above = inherited.first
        var seen: Set<String> = []
        while let superclass = above, seen.insert(superclass).inserted {
            instanceMembers.formUnion(facts.instanceMembers[superclass] ?? [])
            above = facts.superclass[superclass]
        }
        self.members.append(instanceMembers)
        let outer = enter(type: written, members: block)
        defer { self.members.removeLast(); leave(type: outer) }
        try lowerMembers(of: block, owner: qualified, staticMembers: staticMembers, into: &members)
        declaration.members = members
        // `deinit { … }`.
        for member in block.members {
            guard let deinitializer = member.decl.as(DeinitializerDeclSyntax.self), let body = deinitializer.body else { continue }
            let outerState = (tryDepth, leaving)
            tryDepth = 0
            leaving = Leaving(function: leaving.function + 1)
            anonymous.append(false)
            locals.append([])
            defer { locals.removeLast(); (tryDepth, leaving) = outerState; anonymous.removeLast() }
            declaration.deinitializer = try self.block(body.statements, scoped: false)
            declaration.deinitializerNames = NamesUsed(names: names(in: body))
        }
        return declaration
    }

    /// A type's body: its properties, methods, initializers, subscripts and the types inside it.
    mutating func lowerMembers(of block: MemberBlockSyntax, owner qualified: String, staticMembers: Set<String>, into declaration: inout StructDecl) throws {
        // A `typealias` inside a type, which the members name.
        for member in block.members {
            if let alias = member.decl.as(TypeAliasDeclSyntax.self), alias.genericParameterClause == nil {
                aliases[alias.name.text] = try type(alias.initializer.value)
            }
        }
        for member in block.members {
            if member.decl.is(TypeAliasDeclSyntax.self) { continue }
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                let isStaticMember = isStatic(variable.modifiers)
                staticContext = isStaticMember ? (qualified, staticMembers) : nil
                defer { staticContext = nil }
                for property in try properties(variable) {
                    if isStaticMember { declaration.staticProperties.append(property) } else { declaration.properties.append(property) }
                }
            } else if let method = member.decl.as(FunctionDeclSyntax.self) {
                staticContext = isStatic(method.modifiers) ? (qualified, staticMembers) : nil
                defer { staticContext = nil }
                let lowered = try function(method, isMember: true)
                if isStatic(method.modifiers) { declaration.staticMethods.append(lowered) } else { declaration.methods.append(lowered) }
            } else if let initializerNode = member.decl.as(InitializerDeclSyntax.self) {
                declaration.initializers.append(try initializer(initializerNode))
            } else if member.decl.is(StructDeclSyntax.self) || member.decl.is(EnumDeclSyntax.self) || member.decl.is(ClassDeclSyntax.self) {
                pendingNested += try self.declaration(member.decl)
            } else if member.decl.is(DeinitializerDeclSyntax.self) {
                continue // Lowered with the class.
            } else if let subscriptNode = member.decl.as(SubscriptDeclSyntax.self) {
                declaration.subscripts.append(try subscriptDeclaration(subscriptNode))
            } else {
                throw unsupported("'\(member.decl.kind)' in a type", member)
            }
        }
    }

    private mutating func structure(_ node: StructDeclSyntax) throws -> StructDecl {
        let outerParameters = typeParameters
        typeParameters.formUnion(genericParameters(node.genericParameterClause, where: node.genericWhereClause).keys)
        defer { typeParameters = outerParameters }
        let conformances = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        try checkProtocols(conformances)
        let qualified = typePrefix + node.name.text
        var declaration = StructDecl(name: qualified, properties: [], methods: [], initializers: [], conformances: conformances)

        let (instanceMembers, staticMembers) = memberNames(of: node.memberBlock)
        members.append(instanceMembers)
        let outer = enter(type: node.name.text, members: node.memberBlock)
        defer { members.removeLast(); leave(type: outer) }

        try lowerMembers(of: node.memberBlock, owner: qualified, staticMembers: staticMembers, into: &declaration)
        return declaration
    }

    /// `protocol Shape: Named { … }`: its requirements, which carry no bodies.
    private mutating func protocolDeclaration(_ node: ProtocolDeclSyntax) throws -> ProtocolDecl {
        let name = typePrefix + node.name.text
        var declaration = ProtocolDecl(name: name)
        // `protocol P: class` limits it to classes, as AnyObject does.
        declaration.inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription == "class" ? "AnyObject" : $0.type.trimmedDescription } ?? []
        try checkProtocols(declaration.inherited)
        // The types the conforming type chooses are only known to it.
        let outerParameters = typeParameters
        defer { typeParameters = outerParameters }
        for member in node.memberBlock.members {
            if let associated = member.decl.as(AssociatedTypeDeclSyntax.self) {
                declaration.associatedTypes.append(associated.name.text)
                typeParameters.insert(associated.name.text)
            }
        }
        let outerCurrent = currentType
        currentType = name
        defer { currentType = outerCurrent }
        for member in node.memberBlock.members {
            if let method = member.decl.as(FunctionDeclSyntax.self) {
                let generics = genericParameters(method.genericParameterClause, where: method.genericWhereClause)
                let methodParameters = typeParameters
                typeParameters.formUnion(generics.keys)
                defer { typeParameters = methodParameters }
                let effects = method.signature.effectSpecifiers
                let lowered = FunctionDecl(
                    name: method.name.text, parameters: try parameters(method.signature.parameterClause),
                    returnType: try method.signature.returnClause.map { try type($0.type) }, body: Program(statements: []),
                    isMutating: method.modifiers.contains { $0.name.tokenKind == .keyword(.mutating) },
                    isThrowing: effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.throws),
                    isAsync: effects?.asyncSpecifier != nil, generics: generics
                )
                if isStatic(method.modifiers) { declaration.staticMethods.append(lowered) } else { declaration.methods.append(lowered) }
            } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self), let annotation = binding.typeAnnotation else {
                        throw unsupported("this requirement", binding)
                    }
                    var settable = false
                    if case .accessors(let list)? = binding.accessorBlock?.accessors {
                        settable = list.contains { $0.accessorSpecifier.tokenKind == .keyword(.set) }
                    }
                    let property = ProtocolProperty(name: identifier.identifier.text, type: try type(annotation.type), settable: settable)
                    if isStatic(variable.modifiers) { declaration.staticProperties.append(property) } else { declaration.properties.append(property) }
                }
            } else if let initializerNode = member.decl.as(InitializerDeclSyntax.self) {
                declaration.initializers.append(FunctionDecl(
                    name: "init", parameters: try parameters(initializerNode.signature.parameterClause), body: Program(statements: []),
                    isMutating: true, isThrowing: initializerNode.signature.effectSpecifiers?.throwsClause != nil
                ))
            } else if !member.decl.is(AssociatedTypeDeclSyntax.self) && !member.decl.is(TypeAliasDeclSyntax.self) {
                throw unsupported("'\(member.decl.kind)' in a protocol", member)
            }
        }
        return declaration
    }

    /// The types declared inside the one just lowered, to come before it.
    mutating func takeNested() -> [Statement] {
        defer { pendingNested = [] }
        return pendingNested
    }

    /// Enters a type: its qualified name is what it goes by, `Self` is it, and the
    /// types in its body are known by their short names. Gives back how to leave.
    mutating func enter(type name: String, members block: MemberBlockSyntax) -> EnclosingType {
        let outer = EnclosingType(prefix: typePrefix, current: currentType, nested: nestedNames)
        let qualified = typePrefix + name
        typePrefix = qualified + "."
        currentType = qualified
        for member in block.members {
            if let node = member.decl.as(StructDeclSyntax.self) { nestedNames[node.name.text] = typePrefix + node.name.text }
            if let node = member.decl.as(EnumDeclSyntax.self) { nestedNames[node.name.text] = typePrefix + node.name.text }
        }
        return outer
    }

    /// Leaves a type entered, restoring the naming of the one around it.
    mutating func leave(type outer: EnclosingType) {
        (typePrefix, currentType, nestedNames) = (outer.prefix, outer.current, outer.nested)
    }

    /// `subscript(i: Int) -> T { … }`. Its parameters take no label unless two names are written.
    private mutating func subscriptDeclaration(_ node: SubscriptDeclSyntax) throws -> SubscriptDecl {
        guard node.genericParameterClause == nil, node.genericWhereClause == nil else { throw unsupported("a generic subscript", node) }
        var parameters = try self.parameters(node.parameterClause)
        for (index, written) in node.parameterClause.parameters.enumerated() where written.secondName == nil {
            parameters[index].label = nil
        }
        let returnType = try type(node.returnClause.type)
        guard let accessors = node.accessorBlock else { throw unsupported("a subscript without a body", node) }
        func body(_ items: CodeBlockItemListSyntax, _ extra: [String], _ lowering: inout Lowering) throws -> Program {
            lowering.locals.append(Set(parameters.compactMap { $0.name } + extra))
            let outer = (lowering.tryDepth, lowering.leaving)
            lowering.tryDepth = 0
            lowering.leaving = Leaving(function: lowering.leaving.function + 1)
            lowering.anonymous.append(false)
            defer { lowering.locals.removeLast(); (lowering.tryDepth, lowering.leaving) = outer; lowering.anonymous.removeLast() }
            return try lowering.block(items, scoped: false)
        }
        var declaration = SubscriptDecl(parameters: parameters, returnType: returnType, getter: Program(statements: []))
        switch accessors.accessors {
        case .getter(let items):
            declaration.getter = try body(items, [], &self)
            declaration.getterNames = NamesUsed(names: names(in: items))
        case .accessors(let list):
            var sawGetter = false
            for accessor in list {
                guard let items = accessor.body?.statements else { throw unsupported("an accessor without a body", accessor) }
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.get):
                    declaration.getter = try body(items, [], &self)
                    declaration.getterNames = NamesUsed(names: names(in: items))
                    sawGetter = true
                case .keyword(.set):
                    declaration.setterName = accessor.parameters?.name.text ?? "newValue"
                    declaration.setter = try body(items, [declaration.setterName], &self)
                    declaration.setterNames = NamesUsed(names: names(in: items))
                default:
                    throw unsupported("this accessor", accessor)
                }
            }
            guard sawGetter else { throw SyntaxError("a subscript needs a 'get' (line \(line(of: node)))") }
        }
        return declaration
    }

    /// What a type can say it conforms to: the protocols Swiit has, and those declared.
    func checkProtocols(_ names: [String]) throws {
        for name in names where !Lowering.protocols.contains(name) && !declaredTypes.contains(nestedNames[name] ?? name) && bound[name] != .type {
            throw SyntaxError("unknown protocol '\(name)'; Swiit has \(Lowering.protocols.sorted().joined(separator: ", "))")
        }
    }

    /// The first group has a meaning here (the checker checks what they ask
    /// for); the second are markers Swift's own code writes, with nothing to
    /// check or do yet.
    static let protocols: Set = ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence", "Tabular", "Error",
                                 "CaseIterable", "Sendable", "Decodable", "Codable", "AnyObject", "CustomDebugStringConvertible",
                                 "Collection", "BidirectionalCollection", "RandomAccessCollection", "MutableCollection", "RangeReplaceableCollection",
                                 "Numeric", "SignedNumeric", "BinaryInteger", "FixedWidthInteger", "SignedInteger", "UnsignedInteger",
                                 "FloatingPoint", "BinaryFloatingPoint", "IteratorProtocol", "LosslessStringConvertible", "Identifiable",
                                 "ExpressibleByArrayLiteral", "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral"]

    func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
    }

    private mutating func properties(_ node: VariableDeclSyntax) throws -> [PropertyDecl] {
        var properties = try storedAndComputedProperties(node)
        for index in properties.indices {
            properties[index].isLazy = node.modifiers.contains { $0.name.tokenKind == .keyword(.lazy) }
            properties[index].isWeak = node.modifiers.contains { $0.name.tokenKind == .keyword(.weak) || $0.name.tokenKind == .keyword(.unowned) }
            properties[index].isOverride = node.modifiers.contains { $0.name.tokenKind == .keyword(.override) }
            properties[index].isNonisolated = node.modifiers.contains { $0.name.tokenKind == .keyword(.nonisolated) }
        }
        return properties
    }

    private mutating func storedAndComputedProperties(_ node: VariableDeclSyntax) throws -> [PropertyDecl] {
        var properties: [PropertyDecl] = []
        let mutable = node.bindingSpecifier.tokenKind == .keyword(.var)
        // An accessor is a function: `return` leaves it.
        let outer = leaving
        leaving = Leaving(function: leaving.function + 1)
        defer { leaving = outer }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { throw unsupported("this property", binding) }
            let type = try binding.typeAnnotation.map { try self.type($0.type) }
            if let accessors = binding.accessorBlock {
                var property = PropertyDecl(name: identifier.identifier.text, mutable: mutable, type: type)
                switch accessors.accessors {
                case .getter(let body):
                    property.getter = try block(body, scoped: true)
                    property.getterNames = NamesUsed(names: names(in: body))
                case .accessors(let list):
                    for accessor in list {
                        guard let body = accessor.body?.statements else { throw unsupported("an accessor without a body", accessor) }
                        let parameter = accessor.parameters?.name.text
                        let lowered = try block(body, scoped: true)
                        let used = NamesUsed(names: names(in: body))
                        switch accessor.accessorSpecifier.tokenKind {
                        case .keyword(.get):
                            property.getter = lowered
                            property.getterNames = used
                        case .keyword(.set):
                            property.setter = lowered
                            property.setterName = parameter ?? "newValue"
                            property.setterNames = used
                        case .keyword(.willSet):
                            property.willSet = lowered
                            property.willSetName = parameter ?? "newValue"
                            property.willSetNames = used
                        case .keyword(.didSet):
                            property.didSet = lowered
                            property.didSetName = parameter ?? "oldValue"
                            property.didSetNames = used
                        default:
                            throw unsupported("this accessor", accessor)
                        }
                    }
                }
                if property.getter == nil {
                    // Observers go with a stored property, which has a value of its own.
                    guard property.setter == nil else { throw SyntaxError("a property with 'set' needs a 'get' (line \(line(of: binding)))") }
                    property.defaultValue = try binding.initializer.map { try expression($0.value) }
                } else if property.willSet != nil || property.didSet != nil {
                    throw SyntaxError("a computed property can't have willSet or didSet (line \(line(of: binding)))")
                }
                properties.append(property)
            } else {
                var value = try binding.initializer.map { try expression($0.value) }
                // `var x: Int?` starts as nil.
                if value == nil, mutable, case .optional? = type { value = .literal(.nothing) }
                properties.append(PropertyDecl(name: identifier.identifier.text, mutable: mutable, type: type, defaultValue: value))
            }
        }
        return properties
    }

    // MARK: Enums

    private mutating func enumeration(_ node: EnumDeclSyntax) throws -> EnumDecl {
        let outerParameters = typeParameters
        typeParameters.formUnion(genericParameters(node.genericParameterClause, where: node.genericWhereClause).keys)
        defer { typeParameters = outerParameters }
        var rawType: TypeAnnotation?
        var conformances: [String] = []
        for inherited in node.inheritanceClause?.inheritedTypes ?? [] {
            let name = inherited.type.trimmedDescription
            if rawType == nil, conformances.isEmpty, let spelled = TypeAnnotation.spelled(name), [.int, .string, .double].contains(spelled) {
                rawType = spelled
            } else {
                conformances.append(name)
            }
        }
        try checkProtocols(conformances)
        var cases: [EnumCaseDecl] = []
        let qualified = typePrefix + node.name.text
        var declaration = EnumDecl(name: qualified, rawType: rawType, cases: [], conformances: conformances)
        declaration.typeParameters = node.genericParameterClause?.parameters.map(\.name.text) ?? []
        var (instanceMembers, staticMembers) = memberNames(of: node.memberBlock)
        if rawType != nil { instanceMembers.insert("rawValue") }
        members.append(instanceMembers)
        let outer = enter(type: node.name.text, members: node.memberBlock)
        defer { members.removeLast(); leave(type: outer) }
        for member in node.memberBlock.members {
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                for element in caseDecl.elements {
                    let associated: [AssociatedValue] = try element.parameterClause?.parameters.map { parameter in
                        AssociatedValue(label: parameter.firstName?.text, type: try type(parameter.type))
                    } ?? []
                    let raw = try element.rawValue.map { try expression($0.value) }
                    cases.append(EnumCaseDecl(name: element.name.text, rawValue: raw, associated: associated))
                }
            } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                let isStaticMember = isStatic(variable.modifiers)
                staticContext = isStaticMember ? (qualified, staticMembers) : nil
                defer { staticContext = nil }
                for property in try properties(variable) {
                    if isStaticMember {
                        declaration.staticProperties.append(property)
                    } else {
                        guard property.getter != nil else { throw SyntaxError("an enum can't have a stored property: '\(property.name)' (line \(line(of: variable)))") }
                        declaration.properties.append(property)
                    }
                }
            } else if let method = member.decl.as(FunctionDeclSyntax.self) {
                staticContext = isStatic(method.modifiers) ? (qualified, staticMembers) : nil
                defer { staticContext = nil }
                let lowered = try function(method, isMember: true)
                if isStatic(method.modifiers) { declaration.staticMethods.append(lowered) } else { declaration.methods.append(lowered) }
            } else if let initializerNode = member.decl.as(InitializerDeclSyntax.self) {
                declaration.initializers.append(try initializer(initializerNode))
            } else if member.decl.is(StructDeclSyntax.self) || member.decl.is(EnumDeclSyntax.self) {
                pendingNested += try self.declaration(member.decl)
            } else {
                throw unsupported("'\(member.decl.kind)' in an enum", member)
            }
        }
        declaration.cases = cases
        return declaration
    }

    // MARK: Documentation

    /// The `///` lines above a declaration: the summary, and `- Parameter x:` lines.
    func documentation(of node: some SyntaxProtocol) -> Documentation? {
        var lines: [String] = []
        for piece in node.leadingTrivia {
            if case .docLineComment(let text) = piece {
                var line = String(text.dropFirst(3))
                if line.first == " " { line.removeFirst() }
                lines.append(line)
            } else if case .newlines(let count) = piece, count > 1 {
                lines.removeAll()
            }
        }
        guard !lines.isEmpty else { return nil }
        var summary: [String] = []
        var parameters: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("- Parameter "), let colon = line.firstIndex(of: ":") {
                let name = line[line.index(line.startIndex, offsetBy: 12)..<colon].trimmingCharacters(in: .whitespaces)
                parameters[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                summary.append(line)
            }
        }
        return Documentation(summary: summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), parameters: parameters)
    }

    // MARK: Types

    func type(_ node: TypeSyntax) throws -> TypeAnnotation {
        if let identifier = node.as(IdentifierTypeSyntax.self) {
            let name = identifier.name.text
            if typeParameters.contains(name) { return .parameter(name) }
            if Lowering.fixedWidthIntegers.contains(name), identifier.genericArgumentClause == nil, bound[name] == nil, !declaredTypes.contains(name) {
                return .int
            }
            if let target = Lowering.swiftAliases[name], bound[name] == nil, !declaredTypes.contains(name) { return .named(target) }
            let isGenericEnum = facts.genericEnums.contains(nestedNames[name] ?? name) || name == "Result" && declaredTypes.contains("Result") == false && bound["Result"] == .type
            if let clause = identifier.genericArgumentClause, isGenericEnum {
                let arguments = try clause.arguments.map { argument -> TypeAnnotation in
                    guard case .type(let written) = argument.argument else { throw unsupported("this generic argument", argument) }
                    return try type(written)
                }
                return .generic(nestedNames[name] ?? name, arguments)
            }
            if identifier.genericArgumentClause != nil, declaredTypes.contains(nestedNames[name] ?? name) || bound[name] == .type && TypeAnnotation.spelled(name) == nil && Bridge.types[name] == nil {
                // A generic type of the program's own: its arguments only say what it holds.
                return .named(nestedNames[name] ?? name)
            }
            if let clause = identifier.genericArgumentClause {
                let arguments = try clause.arguments.map { argument -> TypeAnnotation in
                    guard case .type(let written) = argument.argument else { throw unsupported("this generic argument", argument) }
                    return try type(written)
                }
                if name == "KeyPath", arguments.count == 2 { return .keyPath(arguments[0], arguments[1]) }
                return TypeAnnotation.spelled(name, arguments) ?? .generic(name, arguments)
            }
            if let alias = aliases[name] { return alias }
            if name == "Self", let current = currentType { return .named(current) }
            if name == "AnyObject", bound[name] == nil, !declaredTypes.contains(name) { return .any }
            if typeParameters.contains(name) { return .parameter(name) }
            if let nested = nestedNames[name] { return .named(nested) }
            if let spelled = TypeAnnotation.spelled(name) { return spelled }
            if name == "Void" { return .void }
            // `any Collection`, `any Numeric`: Swift's protocols as types hold any value.
            if Lowering.protocols.contains(name), bound[name] != .type, !declaredTypes.contains(name) { return .any }
            guard declaredTypes.contains(name) || bound[name] == .type else { throw SyntaxError("unknown type '\(name)'") }
            return .named(name)
        }
        // A nested type: `FilePath.Component`.
        if let member = node.as(MemberTypeSyntax.self), member.genericArgumentClause == nil, let base = dottedName(member.baseType) {
            let name = base + "." + member.name.text
            if let spelled = TypeAnnotation.spelled(name) { return spelled }
            guard declaredTypes.contains(name) || bound[name] == .type else { throw SyntaxError("unknown type '\(name)'") }
            return .named(name)
        }
        if let array = node.as(ArrayTypeSyntax.self) { return .list(try type(array.element)) }
        if let dictionary = node.as(DictionaryTypeSyntax.self) { return .dictionary(try type(dictionary.key), try type(dictionary.value)) }
        if let optional = node.as(OptionalTypeSyntax.self) { return .optional(try type(optional.wrappedType)) }
        // `Foo!`: an optional that is taken to hold a value.
        if let optional = node.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return .optional(try type(optional.wrappedType)) }
        // `T.Type`, `Any.Type`: the type itself as a value.
        if let metatype = node.as(MetatypeTypeSyntax.self) { return .metatype(try type(metatype.baseType)) }
        if let tuple = node.as(TupleTypeSyntax.self) {
            if tuple.elements.isEmpty { return .void }
            if tuple.elements.count == 1, let only = tuple.elements.first, only.firstName == nil { return try type(only.type) }
            return .tuple(try tuple.elements.map { TypeAnnotation.TupleElement(label: $0.firstName?.text, type: try type($0.type)) })
        }
        if let function = node.as(FunctionTypeSyntax.self) {
            let throwing = function.effectSpecifiers?.throwsClause != nil
            let effect: Effect = function.effectSpecifiers?.asyncSpecifier != nil ? .async : .sync
            return .functionType(try function.parameters.map { parameter -> TypeAnnotation in
                let isInout = parameter.type.as(AttributedTypeSyntax.self)?.specifiers.contains { specifier in
                    if case .simpleTypeSpecifier(let simple) = specifier { return simple.specifier.tokenKind == .keyword(.inout) }
                    return false
                } ?? false
                let lowered = try type(parameter.type)
                return isInout ? .inOut(lowered) : lowered
            }, try type(function.returnClause.type),
                                 throws: throwing, async: effect)
        }
        if let attributed = node.as(AttributedTypeSyntax.self) { return try type(attributed.baseType) }
        // `any Shape`, `some Shape`: the protocol's type; `A & B`, the first, which the others add to.
        if let existential = node.as(SomeOrAnyTypeSyntax.self) { return try type(existential.constraint) }
        if let composition = node.as(CompositionTypeSyntax.self), let first = composition.elements.first {
            let parts = try composition.elements.map { try type($0.type) }
            let names = parts.compactMap { part -> String? in if case .named(let name) = part { name } else { nil } }
            // Protocols together: `A & B`. Anything else stands for the first.
            if names.count == parts.count, names.count > 1 { return .named(names.joined(separator: " & ")) }
            return try type(first.type)
        }
        throw unsupported("this type", node)
    }

    private func dottedName(_ node: TypeSyntax) -> String? {
        if let identifier = node.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil { return identifier.name.text }
        if let member = node.as(MemberTypeSyntax.self), member.genericArgumentClause == nil, let base = dottedName(member.baseType) {
            return base + "." + member.name.text
        }
        return nil
    }

    // MARK: Names used

    /// The names a body mentions, so a closure keeps only the variables it uses.
    func names(in node: some SyntaxProtocol) -> Set<String> {
        let collector = NameCollector()
        collector.walk(node)
        var names = collector.names
        // The words in a `$(…)` are the layer's, and a closure that has one needs what they name (a function, a variable).
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset, end = node.endPositionBeforeTrailingTrivia.utf8Offset
        for range in blanked where range.lowerBound >= start && range.upperBound <= end {
            var word = ""
            for byte in bytes[range] + [0x20] {
                let character = Character(UnicodeScalar(byte))
                if character.isLetter || character.isNumber || character == "_" { word.append(character) } else {
                    if !word.isEmpty { names.insert(word); word = "" }
                }
            }
        }
        return names
    }
}

private final class NameCollector: SyntaxVisitor {
    var names: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.baseName.text)
        return .visitChildren
    }
    /// A type named in the body (`x as? T`) counts as a name used, for a type parameter's sake.
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }
}
