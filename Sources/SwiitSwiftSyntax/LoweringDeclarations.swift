@_spi(Shell) import Swiit
import SwiftSyntax
import SwishKit

extension Lowering {
    // MARK: Declarations

    mutating func declaration(_ decl: DeclSyntax) throws -> [Statement] {
        if let node = decl.as(VariableDeclSyntax.self) { return try variables(node) }
        if let node = decl.as(FunctionDeclSyntax.self) {
            functions.insert(node.name.text)
            bind(node.name.text)
            return [.function(try function(node))]
        }
        if let node = decl.as(StructDeclSyntax.self) { return [.structDecl(try structure(node))] }
        if let node = decl.as(EnumDeclSyntax.self) { return [.enumDecl(try enumeration(node))] }
        throw unsupported("'\(decl.kind)'", decl)
    }

    private mutating func variables(_ node: VariableDeclSyntax) throws -> [Statement] {
        guard node.attributes.isEmpty, node.modifiers.isEmpty else { throw unsupported("a modifier on a variable", node) }
        let mutable = node.bindingSpecifier.tokenKind == .keyword(.var)
        var statements: [Statement] = []
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self), binding.accessorBlock == nil else {
                throw unsupported("this variable", binding)
            }
            guard let initializer = binding.initializer else { throw unsupported("a variable without a value", binding) }
            var value = try expression(initializer.value)
            if let annotation = binding.typeAnnotation { value = .annotated(value, try type(annotation.type)) }
            bind(identifier.identifier.text)
            statements.append(.declare(name: identifier.identifier.text, mutable: mutable, value: value))
        }
        return statements
    }

    // MARK: Functions

    mutating func parameters(_ clause: FunctionParameterClauseSyntax) throws -> [Parameter] {
        try clause.parameters.map { parameter in
            var shortFlag: Character?
            var isInput = false
            for attribute in parameter.attributes {
                guard case .attribute(let attribute) = attribute else { throw unsupported("this attribute", parameter) }
                switch attribute.attributeName.trimmedDescription {
                case "flag":
                    guard case .argumentList(let arguments)? = attribute.arguments, arguments.count == 1,
                          let literal = arguments.first?.expression.as(StringLiteralExprSyntax.self),
                          let flag = literal.representedLiteralValue, flag.count == 1, let character = flag.first else {
                        throw unsupported("this @flag", attribute)
                    }
                    shortFlag = character
                case "input", "Input":
                    isInput = true
                default:
                    throw unsupported("the attribute '@\(attribute.attributeName.trimmedDescription)'", attribute)
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
                isInput: isInput, shortFlag: shortFlag
            )
        }
    }

    mutating func function(_ node: FunctionDeclSyntax, isMember: Bool = false) throws -> FunctionDecl {
        guard node.genericParameterClause == nil, node.genericWhereClause == nil else { throw unsupported("generics", node) }
        let effects = node.signature.effectSpecifiers
        guard effects?.asyncSpecifier == nil else { throw unsupported("'async'", node) }
        let parameters = try parameters(node.signature.parameterClause)
        let returnType = try node.signature.returnClause.map { try type($0.type) }
        let mutating = node.modifiers.contains { $0.name.tokenKind == .keyword(.mutating) }
        guard let body = node.body else { throw unsupported("a function without a body", node) }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        defer { locals.removeLast(); (tryDepth, leaving) = outer }
        let program = try block(body.statements, scoped: false)
        return FunctionDecl(
            name: node.name.text, parameters: parameters, returnType: returnType, body: program,
            documentation: documentation(of: node),
            isMutating: mutating, isThrowing: effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.throws),
            isRethrowing: effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.rethrows),
            names: NamesUsed(names: names(in: body))
        )
    }

    private mutating func initializer(_ node: InitializerDeclSyntax) throws -> FunctionDecl {
        guard node.genericParameterClause == nil, node.optionalMark == nil else { throw unsupported("this initializer", node) }
        let parameters = try parameters(node.signature.parameterClause)
        guard let body = node.body else { throw unsupported("an initializer without a body", node) }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        defer { locals.removeLast(); (tryDepth, leaving) = outer }
        let program = try block(body.statements, scoped: false)
        return FunctionDecl(
            name: "init", parameters: parameters, body: program, documentation: documentation(of: node),
            isMutating: true, names: NamesUsed(names: names(in: body))
        )
    }

    // MARK: Structs

    private mutating func structure(_ node: StructDeclSyntax) throws -> StructDecl {
        guard node.genericParameterClause == nil, node.genericWhereClause == nil else { throw unsupported("generics", node) }
        let conformances = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        var declaration = StructDecl(name: node.name.text, properties: [], methods: [], initializers: [], conformances: conformances)

        // The names a method reads through `self`.
        var instanceMembers: Set<String> = []
        for member in node.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self), !isStatic(variable.modifiers) {
                for binding in variable.bindings {
                    if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) { instanceMembers.insert(identifier.identifier.text) }
                }
            }
            if let method = member.decl.as(FunctionDeclSyntax.self), !isStatic(method.modifiers) { instanceMembers.insert(method.name.text) }
        }
        var staticMembers: Set<String> = []
        for member in node.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self), isStatic(variable.modifiers) {
                for binding in variable.bindings {
                    if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) { staticMembers.insert(identifier.identifier.text) }
                }
            }
            if let method = member.decl.as(FunctionDeclSyntax.self), isStatic(method.modifiers) { staticMembers.insert(method.name.text) }
        }
        members.append(instanceMembers)
        defer { members.removeLast() }

        for member in node.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                let isStaticMember = isStatic(variable.modifiers)
                staticContext = isStaticMember ? (node.name.text, staticMembers) : nil
                defer { staticContext = nil }
                for property in try properties(variable) {
                    if isStaticMember { declaration.staticProperties.append(property) } else { declaration.properties.append(property) }
                }
            } else if let method = member.decl.as(FunctionDeclSyntax.self) {
                staticContext = isStatic(method.modifiers) ? (node.name.text, staticMembers) : nil
                defer { staticContext = nil }
                let lowered = try function(method, isMember: true)
                if isStatic(method.modifiers) { declaration.staticMethods.append(lowered) } else { declaration.methods.append(lowered) }
            } else if let initializerNode = member.decl.as(InitializerDeclSyntax.self) {
                declaration.initializers.append(try initializer(initializerNode))
            } else {
                throw unsupported("'\(member.decl.kind)' in a struct", member)
            }
        }
        return declaration
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) }
    }

    private mutating func properties(_ node: VariableDeclSyntax) throws -> [PropertyDecl] {
        var properties: [PropertyDecl] = []
        let mutable = node.bindingSpecifier.tokenKind == .keyword(.var)
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { throw unsupported("this property", binding) }
            let type = try binding.typeAnnotation.map { try self.type($0.type) }
            if let accessors = binding.accessorBlock {
                guard case .getter(let body) = accessors.accessors else { throw unsupported("this accessor", accessors) }
                let getter = try block(body, scoped: true)
                properties.append(PropertyDecl(
                    name: identifier.identifier.text, mutable: mutable, type: type, getter: getter,
                    getterNames: NamesUsed(names: names(in: body))
                ))
            } else {
                let value = try binding.initializer.map { try expression($0.value) }
                properties.append(PropertyDecl(name: identifier.identifier.text, mutable: mutable, type: type, defaultValue: value))
            }
        }
        return properties
    }

    // MARK: Enums

    private mutating func enumeration(_ node: EnumDeclSyntax) throws -> EnumDecl {
        guard node.genericParameterClause == nil else { throw unsupported("generics", node) }
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
        var cases: [EnumCaseDecl] = []
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { throw unsupported("'\(member.decl.kind)' in an enum", member) }
            for element in caseDecl.elements {
                let associated: [AssociatedValue] = try element.parameterClause?.parameters.map { parameter in
                    AssociatedValue(label: parameter.firstName?.text, type: try type(parameter.type))
                } ?? []
                let raw = try element.rawValue.map { try expression($0.value) }
                cases.append(EnumCaseDecl(name: element.name.text, rawValue: raw, associated: associated))
            }
        }
        return EnumDecl(name: node.name.text, rawType: rawType, cases: cases, conformances: conformances)
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
            if let clause = identifier.genericArgumentClause {
                let arguments = try clause.arguments.map { argument -> TypeAnnotation in
                    guard case .type(let written) = argument.argument else { throw unsupported("this generic argument", argument) }
                    return try type(written)
                }
                if name == "KeyPath", arguments.count == 2 { return .keyPath(arguments[0], arguments[1]) }
                return TypeAnnotation.spelled(name, arguments) ?? .generic(name, arguments)
            }
            if let spelled = TypeAnnotation.spelled(name) { return spelled }
            if name == "Void" { return .void }
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
        if let tuple = node.as(TupleTypeSyntax.self) {
            if tuple.elements.isEmpty { return .void }
            if tuple.elements.count == 1, let only = tuple.elements.first, only.firstName == nil { return try type(only.type) }
            return .tuple(try tuple.elements.map { TypeAnnotation.TupleElement(label: $0.firstName?.text, type: try type($0.type)) })
        }
        if let function = node.as(FunctionTypeSyntax.self) {
            let throwing = function.effectSpecifiers?.throwsClause != nil
            return .functionType(try function.parameters.map { try type($0.type) }, try type(function.returnClause.type), throws: throwing)
        }
        if let attributed = node.as(AttributedTypeSyntax.self) { return try type(attributed.baseType) }
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
        return collector.names
    }
}

private final class NameCollector: SyntaxVisitor {
    var names: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.baseName.text)
        return .visitChildren
    }
}
