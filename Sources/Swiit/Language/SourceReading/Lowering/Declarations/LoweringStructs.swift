import SwiftSyntax

// Lowering structs and the members of types: stored and computed properties, methods, nesting.

extension Lowering {
    /// The names a type's methods may use unqualified: its instance members,
    /// read through `self`, and its static ones.
    func memberNames(of block: MemberBlockSyntax) -> (instance: Set<String>, static: Set<String>) {
        var instance: Set<String> = []
        var statics: Set<String> = []
        for member in block.members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                        continue
                    }
                    if isStatic(variable.modifiers) {
                        statics.insert(identifier.identifier.plainName)
                    } else {
                        instance.insert(identifier.identifier.plainName)
                    }
                }
            }
            if let method = member.decl.as(FunctionDeclSyntax.self) {
                if isStatic(method.modifiers) {
                    statics.insert(method.name.plainName)
                } else {
                    instance.insert(method.name.plainName)
                }
            }
        }
        return (instance, statics)
    }

    /// A type's body: its properties, methods, initializers, subscripts and the types inside it.
    mutating func lowerMembers(
        of block: MemberBlockSyntax,
        owner qualified: String,
        staticMembers: Set<String>,
        into declaration: inout StructDecl
    ) throws {
        // A `typealias` inside a type, which the members name.
        for member in block.members {
            if let alias = member.decl.as(TypeAliasDeclSyntax.self),
                alias.genericParameterClause == nil
            {
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
                    if isStaticMember {
                        declaration.staticProperties.append(property)
                    } else {
                        declaration.properties.append(property)
                    }
                }
            } else if let method = member.decl.as(FunctionDeclSyntax.self) {
                staticContext = isStatic(method.modifiers) ? (qualified, staticMembers) : nil
                defer { staticContext = nil }
                let lowered = try function(method, isMember: true)
                if isStatic(method.modifiers) {
                    declaration.staticMethods.append(lowered)
                } else {
                    declaration.methods.append(lowered)
                }
            } else if let initializerNode = member.decl.as(InitializerDeclSyntax.self) {
                declaration.initializers.append(try initializer(initializerNode))
            } else if member.decl.is(StructDeclSyntax.self) || member.decl.is(EnumDeclSyntax.self)
                || member.decl.is(ClassDeclSyntax.self)
            {
                pendingNested += try self.declaration(member.decl)
            } else if member.decl.is(DeinitializerDeclSyntax.self) {
                continue  // Lowered with the class.
            } else if let subscriptNode = member.decl.as(SubscriptDeclSyntax.self) {
                declaration.subscripts.append(try subscriptDeclaration(subscriptNode))
            } else {
                throw unsupported("'\(member.decl.kind)' in a type", member)
            }
        }
    }

    mutating func structure(_ node: StructDeclSyntax) throws -> StructDecl {
        let outerParameters = typeParameters
        typeParameters.formUnion(
            genericParameters(node.genericParameterClause, where: node.genericWhereClause)
                .map(\.name)
        )
        defer { typeParameters = outerParameters }
        let conformances =
            node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        try checkProtocols(conformances)
        let qualified = typePrefix + node.name.text
        var declaration = StructDecl(
            name: qualified,
            properties: [],
            methods: [],
            initializers: [],
            conformances: conformances
        )

        let (instanceMembers, staticMembers) = memberNames(of: node.memberBlock)
        members.append(instanceMembers)
        let outer = enter(type: node.name.text, members: node.memberBlock)
        defer { members.removeLast(); leave(type: outer) }

        try lowerMembers(
            of: node.memberBlock,
            owner: qualified,
            staticMembers: staticMembers,
            into: &declaration
        )
        declaration.isDynamicMemberLookup = hasAttribute("dynamicMemberLookup", node.attributes)
        return declaration
    }

    /// The attributes written on a declaration, as written.
    func attributes(of list: AttributeListSyntax) -> [Symbol.Attribute] {
        list.compactMap { element in
            guard case .attribute(let attribute) = element else { return nil }
            var arguments: [String] = []
            switch attribute.arguments {
            case .argumentList(let list)?: arguments = list.map { $0.trimmedDescription }
            case let other?: arguments = [other.trimmedDescription]
            case nil: break
            }
            return Symbol.Attribute(
                name: attribute.attributeName.trimmedDescription,
                arguments: arguments
            )
        }
    }

    /// Whether a declaration is marked with `@name`.
    func hasAttribute(_ name: String, _ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard case .attribute(let attribute) = element else { return false }
            return attribute.attributeName.trimmedDescription == name
        }
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
            if let node = member.decl.as(StructDeclSyntax.self) {
                nestedNames[node.name.text] = typePrefix + node.name.text
            }
            if let node = member.decl.as(EnumDeclSyntax.self) {
                nestedNames[node.name.text] = typePrefix + node.name.text
            }
        }
        return outer
    }

    /// Leaves a type entered, restoring the naming of the one around it.
    mutating func leave(type outer: EnclosingType) {
        (typePrefix, currentType, nestedNames) = (outer.prefix, outer.current, outer.nested)
    }

    func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains {
            $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
        }
    }

    mutating func properties(_ node: VariableDeclSyntax) throws -> [PropertyDecl] {
        var properties = try storedAndComputedProperties(node)
        for index in properties.indices {
            properties[index].isLazy = node.modifiers.contains {
                $0.name.tokenKind == .keyword(.lazy)
            }
            properties[index].isWeak = node.modifiers.contains {
                $0.name.tokenKind == .keyword(.weak) || $0.name.tokenKind == .keyword(.unowned)
            }
            properties[index].isOverride = node.modifiers.contains {
                $0.name.tokenKind == .keyword(.override)
            }
            properties[index].isNonisolated = node.modifiers.contains {
                $0.name.tokenKind == .keyword(.nonisolated)
            }
        }
        return properties
    }

    private mutating func storedAndComputedProperties(
        _ node: VariableDeclSyntax
    ) throws -> [PropertyDecl] {
        var properties: [PropertyDecl] = []
        let mutable = node.bindingSpecifier.tokenKind == .keyword(.var)
        // An accessor is a function: `return` leaves it.
        let outer = leaving
        leaving = Leaving(function: leaving.function + 1)
        defer { leaving = outer }
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                throw unsupported("this property", binding)
            }
            let type = try binding.typeAnnotation.map { try self.type($0.type) }
            if let accessors = binding.accessorBlock {
                var property = PropertyDecl(
                    name: identifier.identifier.plainName,
                    mutable: mutable,
                    type: type
                )
                switch accessors.accessors {
                case .getter(let body):
                    property.getter = try block(body, scoped: true)
                    property.getterNames = NamesUsed(names: names(in: body))
                case .accessors(let list):
                    for accessor in list {
                        guard let body = accessor.body?.statements else {
                            throw unsupported("an accessor without a body", accessor)
                        }
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
                    guard property.setter == nil else {
                        throw SyntaxError(
                            "a property with 'set' needs a 'get' (line \(line(of: binding)))"
                        )
                    }
                    property.defaultValue = try binding.initializer.map { try expression($0.value) }
                } else if property.willSet != nil || property.didSet != nil {
                    throw SyntaxError(
                        "a computed property can't have willSet or didSet (line \(line(of: binding)))"
                    )
                }
                properties.append(property)
            } else {
                var value = try binding.initializer.map { try expression($0.value) }
                // `var x: Int?` starts as nil.
                if value == nil, mutable, case .optional? = type { value = .literal(.nothing) }
                properties.append(
                    PropertyDecl(
                        name: identifier.identifier.plainName,
                        mutable: mutable,
                        type: type,
                        defaultValue: value
                    )
                )
            }
        }
        return properties
    }
}
