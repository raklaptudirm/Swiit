import Foundation
import SwiitKit

// What the checker knows of a type, in one place. A type's members are declared in one of several places (a struct,
// class or actor; an enum; a protocol; the extensions on any of them, and on Swift's own types) and each kept its own
// description, so every question about a member (its type, how to call it, whether it can be set) was asked of each in
// turn. A `TypeProfile` gathers them: ask it once.

/// A property of a type: stored or computed.
@_spi(Layer) public struct MemberProperty {
    var type: TypeAnnotation
    /// A `var` or a computed property with a setter; a protocol's `{ get set }`.
    var isSettable: Bool
    /// The declaration, if it is a stored property.
    var stored: PropertyDecl?
}

/// MemberSet of one kind of place: what the type declares, or what extensions add.
@_spi(Layer) public struct MemberSet {
    var properties: [String: MemberProperty] = [:]
    @_spi(Layer) public var methods: [String: [TypeChecker.Signature]] = [:]
    var staticProperties: [String: MemberProperty] = [:]
    var staticMethods: [String: [TypeChecker.Signature]] = [:]
    var initializers: [TypeChecker.Signature] = []
}

/// Which set of overloads a method is among, as the interpreter keeps them: the type's own, or the extensions'. A call
/// the checker resolved says which of that set it chose, so the two can't be mixed in one list.
enum MemberOrigin { case declaration, extensions }

/// What `name` is on a type.
enum FoundMember {
    case property(MemberProperty)
    case methods([TypeChecker.Signature], from: MemberOrigin)
    /// A case of an enum, on the type.
    case enumCase
}

extension MemberProperty {
    /// A `static let` or `static var`, stored or computed.
    init(staticDeclaration property: PropertyDecl) {
        self.init(type: property.type ?? .unknown, isSettable: property.mutable && (property.getter == nil || property.setter != nil), stored: property)
    }
}

extension MemberSet {
    /// Adds what `other` has, after this: the methods of a name go on as further overloads, numbered on from this one's.
    mutating func merge(_ other: MemberSet) {
        properties.merge(other.properties) { $1 }
        for (name, signatures) in other.methods {
            methods[name, default: []] += signatures.map { var copy = $0; copy.index = methods[name]?.count ?? 0; return copy }
        }
        staticProperties.merge(other.staticProperties) { first, _ in first }
        for (name, signatures) in other.staticMethods {
            staticMethods[name, default: []] += signatures.map { var copy = $0; copy.index = staticMethods[name]?.count ?? 0; return copy }
        }
        initializers += other.initializers
    }
}

@_spi(Layer) public struct TypeProfile {
    @_spi(Layer) public enum Kind { case structure, classType, actor, enumeration, protocolType, other }

    var name: String
    @_spi(Layer) public var kind: Kind
    var superclass: String?
    var conformances: [String] = []
    /// The protocols a protocol takes in.
    var inherited: [String] = []
    /// An enum's cases, and the type of its raw values.
    @_spi(Layer) public var cases: [(name: String, payload: [AssociatedValue])] = []
    @_spi(Layer) public var rawType: TypeAnnotation?
    var typeParameters: [String] = []
    /// What the type declares itself (for a class, with what its superclass gives), and what extensions add: those of
    /// the type, of the protocols it conforms to, and of its superclasses.
    @_spi(Layer) public var declared = MemberSet()
    var extended = MemberSet()
    /// A struct with no initializer of its own is made by its memberwise one.
    var memberwise: TypeChecker.Signature?
    /// What `value[…]` reads, with whether each can also be written.
    var subscripts: [TypeChecker.Signature] = []
    var subscriptSettable: [Bool] = []
    /// Of a class: which of its initializers are `convenience`, and which of its methods say `override`, by name.
    var convenienceInitializers: [Bool] = []
    var overrides: Set<String> = []
    /// The members an actor gives without `await`.
    var nonisolated: Set<String> = []

    func payload(of name: String) -> [AssociatedValue]? { cases.first { $0.name == name }?.payload }

    /// What Swift synthesizes for an enum: `rawValue` where it has raw values, `allCases` where no case has associated values.
    /// (A Swiit enum isn't a Swift type the bridge could describe, so they are made here.)
    mutating func addSynthesizedEnumMembers() {
        if let rawType { declared.properties["rawValue"] = MemberProperty(type: rawType, isSettable: false, stored: nil) }
        if cases.allSatisfy({ $0.payload.isEmpty }) {
            declared.staticProperties["allCases"] = MemberProperty(type: .list(.named(name)), isSettable: false, stored: nil)
        }
    }

    var isActor: Bool { kind == .actor }
    var isClass: Bool { kind == .classType || kind == .actor }

    /// The initializers a call chooses among: the type's own (or its memberwise one), and those extensions add.
    var initializers: [TypeChecker.Signature] { (declared.initializers.isEmpty ? memberwise.map { [$0] } ?? [] : declared.initializers) + extended.initializers }

    /// Whether a call of an initializer names which it chose, to the interpreter: it keeps the type's own as a set of overloads
    /// that a value type's are in, with none added by extensions, which it keeps apart.
    var namesItsInitializers: Bool { !declared.initializers.isEmpty && !isClass && extended.initializers.isEmpty }

    /// What `name` is on a value of the type: its own members first, then what extensions add.
    func instanceMember(_ name: String) -> FoundMember? {
        if let property = declared.properties[name] { return .property(property) }
        if let methods = declared.methods[name] { return .methods(methods, from: .declaration) }
        if let property = extended.properties[name] { return .property(property) }
        if let methods = extended.methods[name] { return .methods(methods, from: .extensions) }
        return nil
    }

    /// Every static method by that name, the type's own and those extensions add: for an operator, which the overloads of
    /// both are candidates of.
    func staticMethods(named name: String) -> [TypeChecker.Signature] { (declared.staticMethods[name] ?? []) + (extended.staticMethods[name] ?? []) }

    /// What `name` is on the type itself: a static property or method, or a case of an enum.
    func staticMember(_ name: String) -> FoundMember? {
        if let property = declared.staticProperties[name] ?? extended.staticProperties[name] { return .property(property) }
        if let methods = declared.staticMethods[name] { return .methods(methods, from: .declaration) }
        if let methods = extended.staticMethods[name] { return .methods(methods, from: .extensions) }
        if cases.contains(where: { $0.name == name }) { return .enumCase }
        return nil
    }
}


extension TypeChecker {
    /// What is known of `type`, if it names a type with members of its own or ones an extension adds.
    @_spi(Layer) public func describe(_ type: TypeAnnotation) -> TypeProfile? {
        guard let key = extensionKey(of: type) else { return nil }
        return describe(named: key)
    }

    @_spi(Layer) public func describe(named key: String) -> TypeProfile? {
        var description: TypeProfile
        switch lookup(key) {
        case .structType(let profile)?:
            description = profile
        case .enumType(let profile)?:
            description = profile
        case .protocolType(let profile)?:
            description = profile
            description.declared = requirementMembers(of: key)
        default:
            guard let ext = extensionLayer(forKey: key) else { return nil }
            description = TypeProfile(name: key, kind: .other)
            description.extended = ext.members
            description.conformances = ext.conformances
            return description
        }
        if let ext = extensionLayer(forKey: key) {
            description.extended = ext.members
            description.conformances += ext.conformances
        }
        return description
    }

    /// What a protocol asks, with what each protocol it takes in asks.
    private func requirementMembers(of name: String) -> MemberSet {
        var members = MemberSet()
        for required in protocolClosure(name).compactMap({ protocolInfo(named: $0) }) {
            for (property, requirement) in required.declared.properties where members.properties[property] == nil { members.properties[property] = requirement }
            for (method, signatures) in required.declared.methods { members.methods[method, default: []] += signatures }
            for (property, requirement) in required.declared.staticProperties where members.staticProperties[property] == nil { members.staticProperties[property] = requirement }
            for (method, signatures) in required.declared.staticMethods { members.staticMethods[method, default: []] += signatures }
            members.initializers += required.declared.initializers
        }
        for (method, signatures) in members.methods {
            members.methods[method] = signatures.enumerated().map { index, signature in var copy = signature; copy.index = index; return copy }
        }
        return members
    }
}
