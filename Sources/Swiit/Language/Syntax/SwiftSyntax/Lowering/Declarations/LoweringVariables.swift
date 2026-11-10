import SwiftSyntax

// Lowering `let` and `var`: stored and computed variables, and destructuring patterns.

extension Lowering {
    mutating func variables(_ node: VariableDeclSyntax) throws -> [Statement] {
        // `async let x = f()`: `f()` starts as a task the scope owns.
        // Who may see it (`private var x`) matters to no one in a program that is one file.
        let access: Set<Keyword> = [.private, .fileprivate, .internal, .public, .open, .package]
        let modifiers = node.modifiers.filter { modifier in
            if case .keyword(let keyword) = modifier.name.tokenKind {
                return !access.contains(keyword)
            }
            return true
        }
        let isAsync =
            modifiers.count == 1 && modifiers.first?.name.tokenKind == .keyword(.async)
            && node.bindingSpecifier.tokenKind == .keyword(.let)
        // `weak var x: T?`: it holds its instance without keeping it alive.
        let isWeak =
            modifiers.count == 1
            && (modifiers.first?.name.tokenKind == .keyword(.weak)
                || modifiers.first?.name.tokenKind == .keyword(.unowned))
        guard node.attributes.isEmpty, modifiers.isEmpty || isAsync || isWeak else {
            throw unsupported("a modifier on a variable", node)
        }
        let mutable = node.bindingSpecifier.tokenKind == .keyword(.var)
        var statements: [Statement] = []
        for binding in node.bindings {
            // `let _ = f()`: the value, thrown away.
            // `let (a, b) = pair`: the pair held once, and each name from it.
            if let tuple = binding.pattern.as(TuplePatternSyntax.self) {
                guard !isAsync, binding.accessorBlock == nil, let initializer = binding.initializer
                else {
                    throw unsupported("this variable", binding)
                }
                var value = try expression(initializer.value)
                if let annotation = binding.typeAnnotation {
                    value = .annotated(value, try type(annotation.type))
                }
                let pattern = try self.pattern(PatternSyntax(tuple), mutable: mutable)
                destructurings += 1
                let held = InternalName.tuple(destructurings)
                statements.append(.declare(name: held, mutable: false, value: value))
                statements += Lowering.destructure(pattern, of: .variable(held))
                continue
            }
            let name: String
            if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                name = identifier.identifier.plainName
            } else if binding.pattern.is(WildcardPatternSyntax.self) {
                name = "_"
            } else {
                throw unsupported("this variable", binding)
            }
            if binding.accessorBlock != nil {
                guard !isAsync, !isWeak, name != "_",
                    binding.typeAnnotation != nil || binding.initializer != nil
                else {
                    throw unsupported("this variable", binding)
                }
                statements += try computedVariable(
                    name,
                    type: try binding.typeAnnotation.map { try type($0.type) } ?? .any,
                    binding
                )
                continue
            }
            // `var x: Int?` starts as nil; `let y: Int` is given its value later.
            guard let initializer = binding.initializer else {
                guard let annotation = binding.typeAnnotation, !isAsync else {
                    throw unsupported("a variable without a value", binding)
                }
                let written = try type(annotation.type)
                if isWeak {
                    if name != "_" { bind(name) }
                    statements.append(
                        .declare(
                            name: name,
                            mutable: true,
                            value: .call(
                                .variable(InternalName.weak),
                                [
                                    Argument(
                                        value: .annotated(
                                            .literal(.nothing),
                                            {
                                                if case .optional = written {
                                                    written
                                                } else {
                                                    .optional(written)
                                                }
                                            }()
                                        )
                                    )
                                ]
                            )
                        )
                    )
                } else if case .optional = written {
                    if name != "_" { bind(name) }
                    statements.append(
                        .declare(
                            name: name,
                            mutable: true,
                            value: .annotated(.literal(.nothing), written)
                        )
                    )
                } else {
                    if name != "_" { bind(name) }
                    statements.append(
                        .declare(
                            name: name,
                            mutable: true,
                            value: .call(.variable(InternalName.uninitialized), [])
                        )
                    )
                }
                continue
            }
            var value = try expression(initializer.value)
            if isAsync {
                let operation = ClosureLiteral(
                    parameters: [],
                    returnType: try binding.typeAnnotation.map { try type($0.type) },
                    body: Program(
                        statements: [.expression(value)],
                        lines: [line(of: initializer.value)]
                    ),
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

    /// `var total: Int { get { … } set { … } }` outside a type: a getter function, and a setter if
    /// there is one, which a read and an assignment of the name call.
    private mutating func computedVariable(
        _ name: String,
        type: TypeAnnotation,
        _ binding: PatternBindingSyntax
    ) throws -> [Statement] {
        guard let accessors = binding.accessorBlock else { return [] }
        var getter: CodeBlockItemListSyntax?
        var setter: CodeBlockItemListSyntax?
        var willSet: CodeBlockItemListSyntax?, didSet: CodeBlockItemListSyntax?
        var newValue = "newValue", willSetName = "newValue", oldValue = "oldValue"
        switch accessors.accessors {
        case .getter(let body): getter = body
        case .accessors(let list):
            for accessor in list {
                guard let body = accessor.body?.statements else {
                    throw unsupported("an accessor without a body", accessor)
                }
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.get): getter = body
                case .keyword(.set):
                    setter = body; newValue = accessor.parameters?.name.text ?? "newValue"
                case .keyword(.willSet):
                    willSet = body; willSetName = accessor.parameters?.name.text ?? "newValue"
                case .keyword(.didSet):
                    didSet = body; oldValue = accessor.parameters?.name.text ?? "oldValue"
                default: throw unsupported("this accessor on a variable", accessor)
                }
            }
        }
        facts.computedGlobals.insert(name)
        // `var x: T? { didSet { … } }`: a variable of its own, set through a function that runs the
        // observers.
        if getter == nil, willSet != nil || didSet != nil {
            let held = InternalName.stored(name)
            var statements: [Statement] = []
            let start: Expr
            if let initializer = binding.initializer {
                start =
                    type == .any
                    ? try expression(initializer.value)
                    : .annotated(try expression(initializer.value), type)
            } else if case .optional = type {
                start = .annotated(.literal(.nothing), type)
            } else {
                throw unsupported("a variable with observers and no value", binding)
            }
            statements.append(.declare(name: held, mutable: true, value: start))
            let reading = Program(statements: [.returnStatement(.variable(held))])
            statements.append(
                .function(
                    FunctionDecl(
                        name: InternalName.getter(name),
                        parameters: [],
                        returnType: type == .any ? .unknown : type,
                        body: reading
                    )
                )
            )
            func lowered(
                _ body: CodeBlockItemListSyntax,
                parameters: [String]
            ) throws -> [Statement] {
                locals.append(Set(parameters))
                let outer = leaving
                leaving = Leaving(function: leaving.function + 1)
                defer { locals.removeLast(); leaving = outer }
                return try block(body, scoped: false).statements
            }
            var body: [Statement] = []
            if let willSet { body += try lowered(willSet, parameters: [willSetName]).map { $0 } }
            if didSet != nil {
                body.append(.declare(name: oldValue, mutable: false, value: .variable(held)))
            }
            body.append(
                .assign(
                    Assignment(
                        root: held,
                        path: [],
                        op: nil,
                        value: .variable(willSet != nil ? willSetName : "newValue")
                    )
                )
            )
            if let didSet { body += try lowered(didSet, parameters: [oldValue]) }
            let parameter = Parameter(
                label: nil,
                name: willSet != nil ? willSetName : "newValue",
                type: type == .any ? .unknown : type
            )
            statements.append(
                .function(
                    FunctionDecl(
                        name: InternalName.setter(name),
                        parameters: [parameter],
                        returnType: nil,
                        body: Program(statements: body),
                        names: NamesUsed(
                            names: (willSet.map { names(in: $0) } ?? [])
                                .union(didSet.map { names(in: $0) } ?? [])
                        )
                    )
                )
            )
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
        var statements = [
            Statement.function(
                FunctionDecl(
                    name: InternalName.getter(name),
                    parameters: [],
                    returnType: type,
                    body: try lowered(getter, parameters: []),
                    names: NamesUsed(names: names(in: getter))
                )
            )
        ]
        if let setter {
            let parameter = Parameter(label: nil, name: newValue, type: type)
            statements.append(
                .function(
                    FunctionDecl(
                        name: InternalName.setter(name),
                        parameters: [parameter],
                        returnType: nil,
                        body: try lowered(setter, parameters: [parameter]),
                        names: NamesUsed(names: names(in: setter))
                    )
                )
            )
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
}
