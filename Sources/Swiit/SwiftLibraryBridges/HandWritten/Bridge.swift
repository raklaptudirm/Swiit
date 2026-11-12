import Foundation
import Synchronization
import SystemPackage

/// Swift's own types and members, as Swiit sees them: read from the
/// standard library's symbol graph (and swift-system's, for FilePath) by
/// `swiit-bridge`, which writes StandardLibrary.swift and SystemPackage.swift
/// beside this file (see Scripts/bridge
/// and Docs/swift-interop.md). Each member comes with its signature,
/// for the checker, and its glue, which calls Swift.
enum Bridge {
    /// Foundation's `Date` and `AttributedString`, from the description the generator writes
    /// (`FoundationBridge`, made with `--description`), lowered to the form the checker runs.
    static let foundation: [BridgedType] = FoundationBridge.types.map { BridgedType(generated: $0) }
    /// The standard library's types, from its description (`StandardLibraryBridge`).
    static let standardLibrary: [BridgedType] = StandardLibraryBridge.types.map {
        BridgedType(generated: $0)
    }
    /// swift-system's `FilePath`, from its description as well (`SystemBridge`).
    static let system: [BridgedType] = SystemBridge.types.map { BridgedType(generated: $0) }

    /// The bridged types, by the name Swiit writes them with: the core's, and those libraries have
    /// registered. A snapshot, as libraries register while other interpreters read.
    static var types: [String: BridgedType] { table.withLock { $0 } }

    private static let table = Mutex<[String: BridgedType]>(
        Dictionary(
            uniqueKeysWithValues: (standardLibrary + system + foundation + concurrency + [
                BridgedType(generated: stringIndex)
            ])
            .map {
                (
                    $0.name,
                    $0.conforming(to: conformancesDeclaredHere[$0.name] ?? [])
                        .adding(additions(to: $0.name))
                        .withTextInitializer()
                )
            }
        )
    )

    /// Adds the types a library bridges (the host's `FileSize`), which the core does not know, and
    /// the members it adds to types the core has. Registering one again is no change.
    static func register(_ more: [BridgedType]) {
        table.withLock { table in
            for type in more {
                if let existing = table[type.name] {
                    // A library adds members to a type the core has (`String.styled`), as an
                    // extension does.
                    var extended = existing.adding(type.members)
                    // How text becomes one, if the type did not have a way.
                    if extended.parse == nil { extended.parse = type.parse }
                    if extended.literal == nil { extended.literal = type.literal }
                    table[type.name] = extended.withTextInitializer()
                } else {
                    table[type.name] =
                        type.conforming(to: conformancesDeclaredHere[type.name] ?? [])
                        .adding(additions(to: type.name))
                        .withTextInitializer()
                }
            }
        }
    }

    /// Text as a value of the type named, if the type can be text and the
    /// text is one: through its failable initializer from text (`Int`), or
    /// as a text literal (`Character`, `FilePath`). A word of text,
    /// or a string literal where the type is wanted, is converted so.
    static func value(of typeName: String, from text: String) -> Value?? {
        guard let type = types[typeName], type.parse != nil || type.literal != nil else {
            return nil
        }
        return .some(type.parse?(text) ?? type.literal?(text))
    }

    /// The bridged type Swiit's type annotation is, and its generic
    /// parameters' bindings: `[Int]` is `Array` with Element Int.
    static func type(
        of annotation: TypeAnnotation
    ) -> (BridgedType, [String: TypeAnnotation])? {
        guard let (name, arguments) = annotation.swiftType, let type = types[name],
            type.genericParameters.count == arguments.count
        else { return nil }
        return (type, Dictionary(uniqueKeysWithValues: zip(type.genericParameters, arguments)))
    }
}

// Swift's rules for what text literals a type can be, picked the way Swift
// picks: by the most specific literal protocol it conforms to. A string
// literal is any text; a grapheme cluster literal, one Character; a
// Unicode scalar literal, one scalar.

// safe: its state is touched only holding the interpreter lock
/// A bridged type's name as a value, as in `String(sub)` or `Int.max`.
final class BridgedTypeName: LanguageObject, @unchecked Sendable {
    let name: String
    init(_ name: String) { self.name = name }
    var typeName: String { "type" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { name }
}

struct BridgedType: Sendable {
    /// `String`, `Substring`, `Array`.
    let name: String
    /// A generic type's parameters: `Element` for Array.
    let genericParameters: [String]
    /// The protocols it conforms to, of those Swiit knows, each with what
    /// its generic parameters must be for it: a ClosedRange is a Sequence
    /// when its Bound is Int (`["Bound": ["=Int"]]`).
    let conformances: [String: [GenericParameter]]
    /// Its associated types: `Element` is `Character` for String.
    let associatedTypes: [String: TypeAnnotation]
    /// Text as one, through the type's failable initializer from text
    /// (`Int("42")`); nil if the text isn't one.
    var parse: (@Sendable (String) -> Value?)?
    /// Text as one by Swift's rules for text literals (`Character`,
    /// `FilePath`); nil if the text can't be that literal.
    var literal: (@Sendable (String) -> Value?)?
    /// Items as one, for a collection an array literal can be (Array, Set):
    /// what a parameter given several words gets.
    var arrayLiteral: (@Sendable ([Value]) -> Value)?
    let members: [BridgedMember]

    /// It, with the initializer from text Swift gives a type that can be read from it: Swift's
    /// `Double.init?<S: StringProtocol>(_: S)` takes a `String` as well as the `Substring` it is
    /// bridged with, so `Double(text)` does. Nothing is added to a type with one already.
    func withTextInitializer() -> BridgedType {
        guard let parse, let result = TypeAnnotation.spelled(name) else { return self }
        let hasOne = members.contains {
            $0.kind == .initializer && $0.parameters.count == 1 && $0.parameters[0].label == nil
                && $0.parameters[0].type == .string
        }
        guard !hasOne else { return self }
        return adding(
            BridgedMember.bridged(
                [
                    .initializer(
                        summary: "The value the text spells, or nil.",
                        attributes: Bridge.discardable,
                        signature: Symbol.Function(
                            parameters: [Symbol.Parameter(name: "text", type: .string)],
                            returns: .optional(ScriptType(result))
                        )
                    ) { arguments in
                        guard case .string(let text) = arguments[0].storage else { return .nothing }
                        return parse(text) ?? .nothing
                    }
                ],
                in: name
            )
        )
    }

    /// It, with members written by hand too, where the generator can't make them. A host's own member
    /// (one a native type registered) takes the place of a bridged one of the same shape, which is how a
    /// host says how a type shows; one registered twice is not added again.
    func adding(_ extra: [BridgedMember]) -> BridgedType {
        func same(_ a: BridgedMember, _ b: BridgedMember) -> Bool {
            a.kind == b.kind && a.name == b.name && a.isStatic == b.isStatic
                && a.parameters.map(\.label) == b.parameters.map(\.label)
                && a.parameters.map(\.type) == b.parameters.map(\.type)
        }
        let kept = members.filter { old in
            !extra.contains { new in new.plain != nil && old.plain == nil && same(old, new) }
        }
        let extra = extra.filter { new in !kept.contains { same($0, new) } }
        guard !extra.isEmpty || kept.count != members.count else { return self }
        return BridgedType(
            name: name,
            genericParameters: genericParameters,
            conformances: conformances,
            associatedTypes: associatedTypes,
            parse: parse,
            literal: literal,
            arrayLiteral: arrayLiteral,
            members: kept + extra
        )
    }

    /// It, conforming to `protocols` too, whatever its generic parameters are.
    func conforming(to protocols: [String]) -> BridgedType {
        guard !protocols.isEmpty else { return self }
        var all = conformances
        for name in protocols { all[name] = [] }
        return BridgedType(
            name: name,
            genericParameters: genericParameters,
            conformances: all,
            associatedTypes: associatedTypes,
            parse: parse,
            literal: literal,
            arrayLiteral: arrayLiteral,
            members: members
        )
    }

    init(
        name: String,
        genericParameters: [String],
        conformances: [String: [GenericParameter]],
        associatedTypes: [String: TypeAnnotation],
        parse: (@Sendable (String) -> Value?)? = nil,
        literal: (@Sendable (String) -> Value?)? = nil,
        arrayLiteral: (@Sendable ([Value]) -> Value)? = nil,
        members: [BridgedMember]
    ) {
        self.name = name
        self.genericParameters = genericParameters
        self.conformances = conformances
        self.associatedTypes = associatedTypes
        self.parse = parse
        self.literal = literal
        self.arrayLiteral = arrayLiteral
        self.members = members
    }
}

struct BridgedMember: Sendable {
    /// A setter is a property's other half, for `p.extension = "md"`.
    enum Kind { case method, property, initializer, setter }

    let kind: Kind
    let name: String
    let isStatic: Bool
    let parameters: [Parameter]
    let returns: TypeAnnotation
    let generics: [GenericParameter]
    let isThrowing: Bool
    let isRethrowing: Bool
    /// Changes its receiver, like `append`. Its glue gives the result and
    /// the changed receiver, which the host puts back.
    let isMutating: Bool
    /// The attributes it is declared with, as Swift writes them: `@discardableResult` on
    /// `removeLast()`.
    let attributes: [Symbol.Attribute]
    /// Its documentation's first paragraph, from Swift's: what `help` shows.
    let summary: String
    /// Converts the arguments (and `self`), calls Swift, and converts back.
    let body: FunctionBody
    /// What each parameter is, from `- Parameter name:` lines: `help`'s flags.
    var parameterDocs: [String: String] = [:]
    /// `async`: a call, or reading the property, needs `await`. Its glue
    /// waits in `suspend`, so other tasks run meanwhile.
    var effect: Effect = .sync
    /// How a host-registered member is called without an interpreter: what a host object's own
    /// `member(_:)` uses.
    var plain: (@Sendable (Arguments) throws -> Value)?
    /// `throws(Failure)`, for a generic parameter of its type: it throws
    /// unless that is `Never` (`Task<Int, Never>.value` doesn't).
    var typedThrows: String?

    init(
        kind: Kind,
        name: String,
        isStatic: Bool,
        parameters: [Parameter],
        returns: TypeAnnotation,
        generics: [GenericParameter],
        isThrowing: Bool,
        isRethrowing: Bool,
        isMutating: Bool,
        attributes: [Symbol.Attribute] = [],
        summary: String,
        body: FunctionBody,
        parameterDocs: [String: String] = [:],
        effect: Effect = .sync,
        typedThrows: String? = nil
    ) {
        self.effect = effect
        self.typedThrows = typedThrows
        self.kind = kind
        self.name = name
        self.isStatic = isStatic
        self.parameters = parameters
        self.returns = returns
        self.generics = generics
        self.isThrowing = isThrowing
        self.isRethrowing = isRethrowing
        self.isMutating = isMutating
        self.attributes = attributes
        self.summary = summary
        self.body = body
        self.parameterDocs = parameterDocs
    }
}

// MARK: Conversions the glue uses
