import Foundation

enum FunctionBody: Sendable {
    case swiit(Program)
    /// A builtin written in Swift, called with the bound arguments.
    case native(@Sendable (Interpreter, Arguments) throws -> Value)
}

// safe: its state is touched only holding the interpreter lock
/// A Swiit function or closure, or a builtin written in Swift. Both get the
/// same argument binding, help, overloads and streaming.
final class Function: Callable, @unchecked Sendable {
    let name: String?
    let parameters: [Parameter]
    let returnType: TypeAnnotation?
    let body: FunctionBody
    let captured: [Scope]
    let documentation: Documentation?
    /// The attributes it was declared with.
    let attributes: [Symbol.Attribute]
    /// A struct's `mutating func` (or `init`), which may change `self`.
    let isMutating: Bool
    /// `throws`: a call to it needs `try`.
    let isThrowing: Bool
    /// `rethrows`: a call throws if a closure passed to it does.
    let isRethrowing: Bool
    /// `async` if declared so.
    let effect: Effect
    /// Type parameters and their constraints, for a generic builtin.
    let generics: [GenericParameter]
    /// Of those, the ones its body names: a call binds them (`specialized`).
    let typeParameters: Set<String>
    /// The names of its `inout` parameters, which a call hands back.
    let inoutNames: Set<String>
    /// Its result is an optional of what it gives, flattened: an optional it gives back is not made
    /// one more (`flatMap`'s).
    let flattensResult: Bool
    /// `init?`: leaving it with `return nil` makes nothing.
    let isFailable: Bool
    /// `convenience init`: made through another of the class's initializers.
    let isConvenience: Bool
    /// The class whose body it is in, which `super` in it looks above.
    weak var owner: ClassType?

    init(
        name: String?,
        parameters: [Parameter],
        returnType: TypeAnnotation?,
        body: FunctionBody,
        captured: [Scope] = [],
        documentation: Documentation? = nil,
        attributes: [Symbol.Attribute] = [],
        isMutating: Bool = false,
        isThrowing: Bool = false,
        isRethrowing: Bool = false,
        effect: Effect = .sync,
        generics: [GenericParameter] = [],
        isFailable: Bool = false,
        isConvenience: Bool = false,
        typeParameters: Set<String> = [],
        flattensResult: Bool = false
    ) {
        self.flattensResult = flattensResult
        self.typeParameters = typeParameters
        inoutNames = Set(parameters.filter(\.isInout).map(\.name))
        self.isFailable = isFailable
        self.isConvenience = isConvenience
        self.isRethrowing = isRethrowing
        self.effect = effect
        self.generics = generics
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.captured = captured
        self.documentation = documentation
        self.attributes = attributes
    }

    /// It, with `scope` among what it captured: the types of its type parameters, for one call.
    func capturing(_ scope: Scope) -> Function {
        let copy = Function(
            name: name,
            parameters: parameters,
            returnType: returnType,
            body: body,
            captured: captured + [scope],
            documentation: documentation,
            attributes: attributes,
            isMutating: isMutating,
            isThrowing: isThrowing,
            isRethrowing: isRethrowing,
            effect: effect,
            generics: generics,
            isFailable: isFailable,
            isConvenience: isConvenience,
            typeParameters: typeParameters,
            flattensResult: flattensResult
        )
        copy.owner = owner
        return copy
    }

    /// Whether a new declaration would replace this one rather than overload it.
    func hasSameSignature(as other: Function) -> Bool {
        let signature = { (p: Parameter) in [p.label ?? "_", p.type.description, "\(p.variadic)"] }
        return parameters.map(signature) == other.parameters.map(signature)
            && generics == other.generics
    }

    /// As Swift shows any function: by what it is, not its name.
    var description: String { "(Function)" }

    /// Declared by a prelude (the language's, or a host's), though its body is Swiit's.
    var isPrelude = false

    var isBuiltin: Bool {
        if isPrelude { return true }
        if case .swiit = body { return false } else { return true }
    }

    /// A body that is a single expression returns its value, as in Swift:
    /// a closure's, or a function's that says what it returns. A function
    /// without `->` returns nothing.
    private(set) lazy var implicitReturn: Expr? = {
        guard name == nil || returnType != nil, case .swiit(let body) = body,
            body.statements.count == 1,
            case .expression(let expr) = body.statements[0]
        else { return nil }
        return expr
    }()
}

/// What a call binds: each parameter's name and the value it gets, in the order they are bound
/// (the parameters', nearly always). A call binds a handful, for which comparing short names costs
/// less than hashing each into a dictionary; a native body reads them by name as from one.
struct Arguments: Sequence, ExpressibleByDictionaryLiteral {
    private var entries: [(name: String, value: Value)] = []

    init() {}

    /// Room for `capacity` arguments.
    init(capacity: Int) {
        entries.reserveCapacity(capacity)
    }

    init(dictionaryLiteral elements: (String, Value)...) {
        for (name, value) in elements { self[name] = value }
    }

    init(_ dictionary: [String: Value]) {
        for (name, value) in dictionary { self[name] = value }
    }

    private func position(of name: String) -> Int? {
        for index in entries.indices where entries[index].name == name { return index }
        return nil
    }

    subscript(name: String) -> Value? {
        get { position(of: name).map { entries[$0].value } }
        set {
            if let index = position(of: name) {
                if let newValue {
                    entries[index].value = newValue
                } else {
                    entries.remove(at: index)
                }
            } else if let newValue {
                entries.append((name, newValue))
            }
        }
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var keys: [String] { entries.map(\.name) }

    /// As a dictionary, for a host's body, which is promised one.
    var dictionary: [String: Value] {
        Dictionary(entries.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
    }

    func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
        entries.lazy.map { (key: $0.name, value: $0.value) }.makeIterator()
    }
}
