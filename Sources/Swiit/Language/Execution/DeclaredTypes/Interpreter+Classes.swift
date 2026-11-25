import Foundation

// safe: its state is touched only holding the interpreter lock
/// A class a program declares.
final class ClassType: LanguageObject, DeclaredType, @unchecked Sendable {
    let name: String
    let typeRef: TypeRef
    let superclass: ClassType?
    let isActor: Bool
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
    }

    @exclusivity(unchecked) private var chainCache: [ClassType]?
    @exclusivity(unchecked) private var allStoredCache: [PropertyDecl]?

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
    var storage: [String: Value]
    /// What runs when the last reference goes (the class's `deinit`s), if any.
    var onRelease: ((ClassInstance) -> Void)?

    init(type: ClassType, storage: [String: Value] = [:]) {
        self.type = type
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
