import Foundation

// The runtime form of a struct type, and the receiver a method runs on.

/// A struct's definition. Its values are records with its name as their
/// type, so they're values like Swift's structs, and tables, `where`,
/// a host lays them out as it does any record; what the type adds
/// (computed properties, methods, initializers) is looked up through here.
final class StructType: LanguageObject, DeclaredType, @unchecked Sendable {  // safe: its state is touched only holding the interpreter lock
    let name: String
    let id: Symbol.ID
    /// Stored properties, in declaration order: the order of a value's fields.
    let stored: [PropertyDecl]
    let computed: [String: Function]
    let methods: [String: OverloadSet]
    /// Custom initializers; without any, the memberwise one.
    let initializers: OverloadSet?
    let memberwise: Function
    /// The protocols it declares: `struct Point: Equatable`.
    let conformances: [String]
    /// `static let` and `static var`: declared, with their types once checked;
    /// the stored ones' values are in `statics`.
    let staticProperties: [PropertyDecl]
    let staticComputed: [String: Function]
    /// The setters of `static var`s that are computed.
    var staticSetters: [String: Function] = [:]
    let staticMethods: [String: OverloadSet]
    var statics: [String: StaticValue] = [:]
    /// `subscript(…)`: each getter, and the setter of the same position if it has one (its
    /// parameters are the getter's, then the new value).
    var subscriptGetters: [Function] = []
    var subscriptSetters: [Function?] = []
    /// `@dynamicMemberLookup`, which the checker reads.
    var isDynamicMemberLookup = false
    /// What setting a computed property runs, with its value as the one parameter.
    var setters: [String: Function] = [:]
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
        staticMethods: [String: OverloadSet] = [:]
    ) {
        self.name = name
        self.id = .declare(name)
        self.conformances = conformances
        self.staticProperties = staticProperties
        self.staticComputed = staticComputed
        self.staticMethods = staticMethods
        self.stored = stored
        self.computed = computed
        self.methods = methods
        self.initializers = initializers
        self.memberwise = memberwise
    }

    func property(_ name: String) -> PropertyDecl? {
        stored.first { $0.name == name }
    }

    func staticProperty(_ name: String) -> PropertyDecl? {
        staticProperties.first { $0.name == name }
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
