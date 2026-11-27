import Foundation

// The runtime form of a struct type, and the receiver a method runs on.

// safe: its state is touched only holding the interpreter lock
/// A struct's definition. Its values are records with its name as their
/// type, so they're values like Swift's structs, and tables, `where`,
/// a host lays them out as it does any record; what the type adds
/// (computed properties, methods, initializers) is looked up through here.
final class StructType: LanguageObject, DeclaredType, @unchecked Sendable {
    let name: String
    let typeRef: TypeRef
    /// Stored properties, in declaration order: the order of a value's fields.
    let stored: [PropertyDecl]
    /// The names of `stored`, in the same order: the keys of a value's fields.
    let storedNames: [String]
    /// What the type adds to its values and to itself: computed properties and their setters, methods,
    /// initializers, statics and subscripts. A struct, an enum and an extension keep them the same way.
    let members = TypeMembers()
    /// How its values are stored: as records of the stored properties.
    let representation = ImplementedType.Representation.record
    /// What is said of the type, apart from its conformances, which `Interpreter.typeSymbol` adds
    /// because extensions give them too.
    let symbol: Symbol.Nominal
    let memberwise: Function
    /// The protocols it declares: `struct Point: Equatable`.
    let conformances: [String]
    /// `@dynamicMemberLookup`, which the checker reads.
    var isDynamicMemberLookup = false
    /// What the memberwise initializer does with each argument, worked out the first time the loop
    /// constructs a value through it (`Interpreter.memberwisePlan(of:)`).
    @exclusivity(unchecked) var memberwisePlan: MemberwisePlan?
    @exclusivity(unchecked) var hasMemberwisePlan = false
    /// The fields a new value starts with, when every default is a literal, so that they need not be
    /// worked out again (`Interpreter.startingRecord(of:)`).
    @exclusivity(unchecked) var startingFields: Value.Record?
    @exclusivity(unchecked) var hasStartingFields = false
    /// What runs before and after a stored property changes.
    var observers: [String: (willSet: Function?, didSet: Function?)] = [:]

    /// A stored static property's value, kept on the type.
    final class StaticValue {
        var value: Value
        let mutable: Bool

        init(_ value: Value, mutable: Bool) {
            self.value = value
            self.mutable = mutable
        }
    }

    init(
        name: String,
        stored: [PropertyDecl],
        computed: [String: Function],
        methods: [String: OverloadSet],
        initializers: OverloadSet?,
        memberwise: Function,
        conformances: [String] = [],
        staticProperties: [PropertyDecl] = [],
        staticComputed: [String: Function] = [:],
        staticMethods: [String: OverloadSet] = [:],
        typeRef: TypeRef? = nil
    ) {
        self.name = name
        self.typeRef = typeRef ?? .declare(name)
        symbol = Symbol.Nominal(name: name, kind: .structure, typeRef: self.typeRef)
        self.conformances = conformances
        self.stored = stored
        storedNames = stored.map(\.name)
        self.memberwise = memberwise
        members.computed = computed
        members.methods = methods
        members.initializers = initializers
        members.staticProperties = staticProperties
        members.staticComputed = staticComputed
        members.staticMethods = staticMethods
    }

    func property(_ name: String) -> PropertyDecl? {
        stored.first { $0.name == name }
    }

    func staticProperty(_ name: String) -> PropertyDecl? {
        members.staticProperties.first { $0.name == name }
    }

    var typeName: String { "struct" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { "struct \(name)" }
}

/// `self` for a method: its value going in, and as the method left it.
final class Receiver {
    var value: Value
    let mutable: Bool
    /// In an `init`, which may also set `let` properties.
    let initializing: Bool

    init(_ value: Value, mutable: Bool, initializing: Bool = false) {
        self.value = value
        self.mutable = mutable
        self.initializing = initializing
    }
}
