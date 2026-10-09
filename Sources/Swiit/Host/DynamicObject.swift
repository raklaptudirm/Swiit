import SwishKit

/// A host object whose members aren't declared one by one: `env`, whose
/// members are the process's variables. Reading a member or indexing by a
/// string asks the object, assigning writes to it, and the checker types
/// every member the same, so `env.HOME` is a `String?` and `env.PAGER = "less"`
/// takes one.
///
/// It is a reference: assigning through a `let` binding is allowed, as with a
/// class in Swift. (A registered object is the Lua userdata with `__index` and
/// `__newindex`; the same feature serves JSON as a real type.)
@_spi(Shell) public protocol DynamicObject: SwishObject {
    /// What reading any member, or indexing by a String, gives.
    var readType: TypeAnnotation { get }
    /// What assigning to a member takes; nil removes it, if that makes sense.
    var writeType: TypeAnnotation { get }
    /// The member called `name`; nothing when it has none.
    func read(_ name: String) throws -> Value
    func write(_ name: String, _ value: Value) throws
}

/// What the checker knows of a dynamic type, by its name: an object's members
/// (`env`), or the members of plain values that a host types as one of its
/// own (parsed JSON).
@_spi(Shell) public struct DynamicType {
    @_spi(Shell) public var read: TypeAnnotation
    @_spi(Shell) public var write: TypeAnnotation
    /// Set for values that aren't objects but plain values, read by name.
    @_spi(Shell) public var plain: PlainDynamic?

    @_spi(Shell) public init(read: TypeAnnotation, write: TypeAnnotation, plain: PlainDynamic? = nil) {
        self.read = read
        self.write = write
        self.plain = plain
    }
}

/// A type whose values are whatever they were parsed as, and whose members are
/// looked up when it runs (nil if missing): the checker writes each access
/// into a call of the host's functions, so the values stay ordinary lists,
/// records and scalars. Parsed JSON is one: `json.name`, `json[0]`,
/// `json.port?.int`.
@_spi(Shell) public struct PlainDynamic {
    /// A function in scope, `field(value, key)`: the member or element, or nil.
    @_spi(Shell) public var field: String
    /// A function in scope, `view(value, "int")`: the value as that type, or nil.
    @_spi(Shell) public var view: String
    /// The types of the views by name: `int` gives `Int?`.
    @_spi(Shell) public var views: [String: TypeAnnotation]
    /// What a sequence's items are, when it is read as one.
    @_spi(Shell) public var element: TypeAnnotation
    /// It fits wherever a type is wanted, being whatever it parsed as.
    @_spi(Shell) public var standsForAnything: Bool

    @_spi(Shell) public init(field: String, view: String, views: [String: TypeAnnotation], element: TypeAnnotation, standsForAnything: Bool = true) {
        self.field = field
        self.view = view
        self.views = views
        self.element = element
        self.standsForAnything = standsForAnything
    }
}

extension Interpreter {
    /// Binds `name` to a dynamic object in the outermost scope, and tells the
    /// checker the type of its members.
    @_spi(Shell) public func bind(_ name: String, to object: some DynamicObject) {
        dynamicTypes[object.typeName] = DynamicType(read: object.readType, write: object.writeType)
        scopes[0].bindings[name] = Binding(value: .object(object), mutable: false)
    }
}

extension TypeChecker {
    /// The members' types if `type` is a dynamic object's.
    @_spi(Shell) public func dynamicType(of type: TypeAnnotation) -> DynamicType? {
        guard case .named(let name) = type, let dynamic = interpreter.dynamicTypes[name], dynamic.plain == nil else { return nil }
        return dynamic
    }

    /// How a plain dynamic type (parsed JSON) is read, if `type` is one.
    @_spi(Shell) public func plainType(of type: TypeAnnotation?) -> (type: DynamicType, plain: PlainDynamic)? {
        guard case .named(let name)? = type, let dynamic = interpreter.dynamicTypes[name], let plain = dynamic.plain else { return nil }
        return (dynamic, plain)
    }

    /// `value.name` on a plain dynamic type as it runs: a call that gives nil
    /// for a missing member, or the value as one of the views' types.
    @_spi(Shell) public func plainAccess(_ type: TypeAnnotation?, _ base: Expr, _ name: String) -> Expr? {
        guard let (_, plain) = plainType(of: type) else { return nil }
        let function = plain.views[name] != nil ? plain.view : plain.field
        return .call(.variable(function), [Argument(label: nil, value: base), Argument(label: nil, value: .literal(.string(name)))])
    }

    /// `value[key]` on a plain dynamic type as it runs.
    @_spi(Shell) public func plainIndex(_ type: TypeAnnotation?, _ base: Expr, _ index: Expr) -> Expr? {
        guard let (_, plain) = plainType(of: type) else { return nil }
        return .call(.variable(plain.field), [Argument(label: nil, value: base), Argument(label: nil, value: index)])
    }
}

extension Value {
    /// Whether it is a dynamic object, which is assigned through, not replaced.
    @_spi(Shell) public var isDynamicObject: Bool {
        if case .object(let object) = self { return object is DynamicObject }
        return false
    }
}
