import Foundation

// safe: its state is touched only holding the interpreter lock
/// A class a program declares.
final class ClassType: LanguageObject, DeclaredType, @unchecked Sendable {
    let name: String
    let typeRef: TypeRef
    let superclass: ClassType?
    let isActor: Bool

    // safe: `ClassType.deinit` clears it, and it is read holding the interpreter lock, so it is alive
    /// How the methods of the class refer to it without keeping it alive: the link holds the class
    /// without counting it, and is cleared as the class goes.
    final class Link: @unchecked Sendable {
        unowned(unsafe) var type: ClassType?
    }
    let link = Link()

    deinit { link.type = nil }

    /// Stored properties this class declares, in order, and their defaults.
    let stored: [PropertyDecl]
    /// What the class declares itself, not what it inherits: computed properties and their setters,
    /// methods, initializers, statics and subscripts, kept as a struct, an enum and an extension do.
    let members = TypeMembers()
    /// How its instances are stored: as a reference, shared by every variable that holds it.
    let representation = ImplementedType.Representation.reference
    var observers: [String: (willSet: Function?, didSet: Function?)] = [:]
    var deinitializer: Function?
    /// The protocols it names itself.
    let conformances: [String]
    /// What it was declared as in source, which the checker reads again for a later program.
    var source: ClassDecl?
    /// What is said of the type, apart from its conformances, which `Interpreter.typeSymbol` adds
    /// because extensions give them too.
    let symbol: Symbol.Nominal

    init(
        name: String,
        superclass: ClassType?,
        isActor: Bool,
        stored: [PropertyDecl],
        staticProperties: [PropertyDecl],
        conformances: [String],
        typeRef: TypeRef? = nil
    ) {
        self.name = name
        self.typeRef = typeRef ?? .declare(name)
        self.superclass = superclass
        self.isActor = isActor
        self.stored = stored
        self.conformances = conformances
        members.staticProperties = staticProperties
        symbol = Symbol.Nominal(name: name, kind: isActor ? .actor : .class, typeRef: self.typeRef)
        link.type = self
    }

    @exclusivity(unchecked) private var chainCache: [ClassType]?
    @exclusivity(unchecked) private var allStoredCache: [PropertyDecl]?
    @exclusivity(unchecked) private var instancePlanCache: InstancePlan?

    /// This class and each it comes from, nearest first. Made once: where a class comes from does not
    /// change.
    var chain: [ClassType] {
        if let chainCache { return chainCache }
        var result: [ClassType] = []
        var current: ClassType? = self
        while let next = current {
            result.append(next)
            current = next.superclass
        }
        chainCache = result
        return result
    }

    /// Every stored property, those of the oldest class first.
    var allStored: [PropertyDecl] {
        if let allStoredCache { return allStoredCache }
        let result = chain.reversed().flatMap(\.stored)
        allStoredCache = result
        return result
    }

    /// What an instance starts as, worked out once from the properties: each name, and whether it begins
    /// with a literal, with what evaluating its default gives, or with nothing.
    var instancePlan: InstancePlan {
        if let instancePlanCache { return instancePlanCache }
        let plan = InstancePlan(
            allStored,
            hasDeinit: chain.contains { $0.deinitializer != nil },
            hasSuperclass: superclass != nil
        )
        instancePlanCache = plan
        return plan
    }

    /// The protocols named by it and the classes it comes from.
    var allConformances: [String] { chain.flatMap(\.conformances) }

    func isSubclass(of other: ClassType) -> Bool { chain.contains { $0 === other } }

    /// The methods by that name, the nearest class's first, one for each signature (the nearer
    /// overrides). The subscripts of the nearest class that declares any.
    var subscriptOwner: ClassType? { chain.first { !$0.members.subscriptGetters.isEmpty } }

    func allMethods(_ name: String) -> [Function] {
        var found: [Function] = []
        for type in chain {
            for method in type.members.methods[name]?.candidates ?? []
            where !found.contains(where: { $0.hasSameSignature(as: method) }) {
                found.append(method)
            }
        }
        return found
    }

    func property(_ name: String) -> PropertyDecl? {
        for type in chain {
            if let property = type.stored.first(where: { $0.name == name }) { return property }
        }
        return nil
    }

    func computedProperty(_ name: String) -> Function? {
        chain.lazy.compactMap { $0.members.computed[name] }.first
    }

    func setter(_ name: String) -> Function? {
        chain.lazy.compactMap { $0.members.setters[name] }.first
    }

    func observer(_ name: String) -> (willSet: Function?, didSet: Function?)? {
        chain.lazy.compactMap { $0.observers[name] }.first
    }

    var typeName: String { "class" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { name }
}

// safe: its state is touched only holding the interpreter lock
/// A value of a class: shared by every variable that holds it.
final class ClassInstance: LanguageObject, @unchecked Sendable {
    let type: ClassType
    /// What its class says of its instances, kept here so that the checks a construction makes read it
    /// and not the class.
    let plan: InstancePlan
    var storage: FieldTable
    /// What runs when the last reference goes (the class's `deinit`s), if any.
    var onRelease: ((ClassInstance) -> Void)?

    init(type: ClassType, storage: FieldTable = FieldTable()) {
        self.type = type
        plan = type.instancePlan
        self.storage = storage
    }

    deinit {
        onRelease?(self)
    }

    var typeName: String { type.name }
    var memberNames: [String] { type.allStored.map(\.name) }
    func member(_ name: String) -> Value? { storage[name] }
    var description: String { type.name }
}

/// The fields of a class's instance, by name: a class has a handful, which are found by comparing
/// names, as a struct's are (`Value.Record`), with no hashing and no table to grow as they are set.
struct FieldTable: Sequence, ExpressibleByDictionaryLiteral {
    private struct Field {
        let name: String
        var value: Value
    }

    private var fields: [Field] = []

    init() {}

    init(dictionaryLiteral elements: (String, Value)...) {
        for (name, value) in elements { self[name] = value }
    }

    /// An empty table with room for `capacity` fields.
    init(capacity: Int) {
        fields.reserveCapacity(capacity)
    }

    private func position(of name: String) -> Int? {
        for index in fields.indices where fields[index].name == name { return index }
        return nil
    }

    subscript(name: String) -> Value? {
        get { position(of: name).map { fields[$0].value } }
        set {
            if let index = position(of: name) {
                if let newValue { fields[index].value = newValue } else { fields.remove(at: index) }
            } else if let newValue {
                fields.append(Field(name: name, value: newValue))
            }
        }
    }

    var count: Int { fields.count }
    var isEmpty: Bool { fields.isEmpty }
    var keys: [String] { fields.map(\.name) }
    var values: [Value] { fields.map(\.value) }

    func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
        fields.lazy.map { (key: $0.name, value: $0.value) }.makeIterator()
    }
}

/// What the instances of a class start as: for each stored property, in the order of `allStored`, its
/// name and how it begins, which `Interpreter.initialValue(of:)` works out for one property and is the
/// same for each instance unless its default is an expression.
final class InstancePlan {
    enum Start {
        /// It has no value until the initializer sets it (a `lazy` one, or one with no default).
        case absent
        /// A literal of its own kind, or nil for an optional `var`.
        case value(Value)
        /// A default that is evaluated for each instance.
        case evaluated
    }

    let names: [String]
    let starts: [Start]
    /// The names of those that must be set when an initializer ends.
    let required: [String]
    /// A class of the chain has a `deinit`.
    let hasDeinit: Bool
    /// It comes from a class, whose `init()` an initializer that does not call `super.init` runs.
    let hasSuperclass: Bool

    init(_ properties: [PropertyDecl], hasDeinit: Bool, hasSuperclass: Bool) {
        self.hasSuperclass = hasSuperclass
        names = properties.map(\.name)
        required = properties.filter { !$0.isLazy }.map(\.name)
        self.hasDeinit = hasDeinit
        starts = properties.map { property in
            if property.isLazy { return .absent }
            if case .literal(let value)? = property.defaultValue, !property.isWeak,
                property.type.map({ ParameterKind($0).accepts(value) }) ?? true
            {
                return .value(value)
            }
            if property.defaultValue != nil { return .evaluated }
            if property.mutable, property.type?.optionalWrapped != nil { return .value(.nothing) }
            return .absent
        }
    }
}
