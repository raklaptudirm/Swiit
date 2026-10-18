import Foundation

/// A class a program declares.
public final class ClassType: SwiitObject, @unchecked Sendable { // safe: its state is touched only holding the interpreter lock
    public let name: String
    public let superclass: ClassType?
    let isActor: Bool
    /// Stored properties this class declares, in order, and their defaults.
    let stored: [PropertyDecl]
    var computed: [String: Function] = [:]
    var setters: [String: Function] = [:]
    var observers: [String: (willSet: Function?, didSet: Function?)] = [:]
    var methods: [String: [Function]] = [:]
    var initializers: [Function] = []
    var deinitializer: Function?
    var subscriptGetters: [Function] = []
    var subscriptSetters: [Function?] = []
    var staticComputed: [String: Function] = [:]
    var staticMethods: [String: [Function]] = [:]
    var statics: [String: StructType.StaticValue] = [:]
    let staticProperties: [PropertyDecl]
    /// The protocols it names itself.
    public let conformances: [String]

    init(name: String, superclass: ClassType?, isActor: Bool, stored: [PropertyDecl], staticProperties: [PropertyDecl], conformances: [String]) {
        self.name = name
        self.superclass = superclass
        self.isActor = isActor
        self.stored = stored
        self.staticProperties = staticProperties
        self.conformances = conformances
    }

    /// This class and each it comes from, nearest first.
    var chain: [ClassType] {
        var result: [ClassType] = []
        var current: ClassType? = self
        while let next = current {
            result.append(next)
            current = next.superclass
        }
        return result
    }

    /// Every stored property, those of the oldest class first.
    var allStored: [PropertyDecl] { chain.reversed().flatMap(\.stored) }

    /// The protocols named by it and the classes it comes from.
    var allConformances: [String] { chain.flatMap(\.conformances) }

    func isSubclass(of other: ClassType) -> Bool { chain.contains { $0 === other } }

    /// The methods by that name, the nearest class's first, one for each signature (the nearer overrides).
    /// The subscripts of the nearest class that declares any.
    var subscriptOwner: ClassType? { chain.first { !$0.subscriptGetters.isEmpty } }

    func allMethods(_ name: String) -> [Function] {
        var found: [Function] = []
        for type in chain {
            for method in type.methods[name] ?? [] where !found.contains(where: { $0.hasSameSignature(as: method) }) {
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
        chain.lazy.compactMap { $0.computed[name] }.first
    }

    func setter(_ name: String) -> Function? {
        chain.lazy.compactMap { $0.setters[name] }.first
    }

    func observer(_ name: String) -> (willSet: Function?, didSet: Function?)? {
        chain.lazy.compactMap { $0.observers[name] }.first
    }

    public var typeName: String { "class" }
    public var memberNames: [String] { [] }
    public func member(_ name: String) -> Value? { nil }
    public var fields: Record? { nil }
    public var description: String { name }
}

/// A value of a class: shared by every variable that holds it.
public final class ClassInstance: SwiitObject, @unchecked Sendable { // safe: its state is touched only holding the interpreter lock
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

    public var typeName: String { type.name }
    public var memberNames: [String] { type.allStored.map(\.name) }
    public func member(_ name: String) -> Value? { storage[name] }
    public var description: String { type.name }
}

@_spi(Layer) extension ClassType: LanguageObject {}
@_spi(Layer) extension ClassInstance: LanguageObject {}
