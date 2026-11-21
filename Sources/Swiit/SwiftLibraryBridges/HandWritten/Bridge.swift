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
    /// Swift's protocols that a sequence conforms to by being a collection of one kind or another:
    /// an extension of one reaches every sequence, as Swiit does not tell them apart.
    static let sequenceProtocols: Set = [
        "Sequence", "Collection", "BidirectionalCollection", "RandomAccessCollection",
    ]

    /// The protocols every script value conforms to, so a generic parameter bound by one is met.
    static let valueProtocols: Set = ["Equatable", "Hashable", "Comparable"]

    /// Foundation's `Date` and `AttributedString`, from the description the generator writes
    /// (`FoundationBridge`, made with `--description`), lowered to the form the checker runs.
    static let foundation: [ImplementedType] = FoundationBridge.types.map {
        $0.lowering(ofTheCore: true)
    }
    /// The standard library's types, from its description (`StandardLibraryBridge`).
    static let standardLibrary: [ImplementedType] = StandardLibraryBridge.types.map {
        $0.lowering(ofTheCore: true)
    }
    /// swift-system's `FilePath`, from its description as well (`SystemBridge`).
    static let system: [ImplementedType] = SystemBridge.types.map {
        $0.lowering(ofTheCore: true)
    }

    /// The bridged types, by the name Swiit writes them with: the core's, and those libraries have
    /// registered. A snapshot, as libraries register while other interpreters read.
    static var types: [String: ImplementedType] { table.withLock { $0 } }

    private static let table = Mutex<[String: ImplementedType]>(
        Dictionary(
            uniqueKeysWithValues: (standardLibrary + system + foundation + concurrency)
                .map {
                    (
                        $0.name,
                        $0.conforming(to: conformancesDeclaredHere[$0.name] ?? [])
                            .adding(additions(to: $0.name))
                    )
                }
        )
    )

    /// Adds the types a library bridges (the host's `FileSize`), which the core does not know, and
    /// the members it adds to types the core has. Registering one again is no change.
    static func register(_ more: [ImplementedType]) {
        table.withLock { table in
            for type in more {
                if let existing = table[type.name] {
                    // A library adds members to a type the core has (`String.styled`), as an
                    // extension does.
                    table[type.name] = existing.adding(type.lowered)
                } else {
                    table[type.name] =
                        type.conforming(to: conformancesDeclaredHere[type.name] ?? [])
                        .adding(additions(to: type.name))
                }
            }
        }
    }

    /// The bridged type Swiit's type annotation is, and its generic
    /// parameters' bindings: `[Int]` is `Array` with Element Int.
    static func type(
        of annotation: TypeAnnotation
    ) -> (ImplementedType, [String: TypeAnnotation])? {
        guard let (name, arguments) = annotation.swiftType, let type = types[name],
            type.genericParameterNames.count == arguments.count
        else { return nil }
        return (type, Dictionary(uniqueKeysWithValues: zip(type.genericParameterNames, arguments)))
    }
}

// Swift's rules for what text literals a type can be, picked the way Swift
// picks: by the most specific literal protocol it conforms to. A string
// literal is any text; a grapheme cluster literal, one Character; a
// Unicode scalar literal, one scalar.

// safe: its state is touched only holding the interpreter lock
/// A bridged type's name as a value, as in `String(sub)` or `Int.max`.
final class NativeTypeName: LanguageObject, @unchecked Sendable {
    let name: String
    init(_ name: String) { self.name = name }
    var typeName: String { "type" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { name }
}

struct BridgedMember: Sendable {
    /// A setter is a property's other half, for `p.extension = "md"`.
    enum Kind { case method, property, initializer, setter }

    let kind: Kind
    let name: String
    let isStatic: Bool
    let parameters: [Parameter]
    let returns: TypeAnnotation
    let generics: [Symbol.GenericParameter]
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
        generics: [Symbol.GenericParameter],
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
