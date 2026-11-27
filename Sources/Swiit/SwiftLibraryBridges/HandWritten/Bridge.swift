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

    /// The types the core bridges, by the name Swiit writes them with: what every interpreter starts
    /// with, and the same for all of them.
    static let core: [String: ImplementedType] = Dictionary(
        uniqueKeysWithValues: (standardLibrary + system + foundation + concurrency)
            .map {
                (
                    $0.name,
                    $0.conforming(to: conformancesDeclaredHere[$0.name] ?? [])
                        .adding(additions(to: $0.name))
                )
            }
    )

    /// The bridged types as code that runs outside any interpreter can see them: the core's, and
    /// those any interpreter has registered, the first registration of a name winning. An
    /// interpreter reads its own (`Interpreter.bridged`), which another's registrations do not
    /// change.
    static var types: [String: ImplementedType] { table.withLock { $0 } }

    private static let table = Mutex<[String: ImplementedType]>(core)

    /// The bridged types of the interpreter running script code on this thread, or what outside
    /// code sees where none is: for a place that has no interpreter to ask.
    static var current: [String: ImplementedType] { Interpreter.running?.bridged ?? types }

    /// Adds the types a library bridges (the host's `FileSize`), which the core does not know, and
    /// the members it adds to types the core has, to an interpreter's table and to the one outside
    /// code reads. Registering one again is no change.
    static func register(_ more: [ImplementedType], in own: inout [String: ImplementedType]) {
        add(more, to: &own)
        table.withLock { add(more, to: &$0) }
    }

    private static func add(_ more: [ImplementedType], to table: inout [String: ImplementedType]) {
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

    /// The bridged type a checked type is, and its generic
    /// parameters' bindings: `[Int]` is `Array` with Element Int.
    static func type(
        of annotation: TypeExpression,
        in types: [String: ImplementedType]
    ) -> (ImplementedType, [String: TypeExpression])? {
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

    /// Whose member it is.
    enum Origin {
        /// A member of a type the core bridges, from its description.
        case bridged
        /// A member a host registered, which takes the place of a bridged one of the same shape:
        /// how a host says how a type shows.
        case host
    }

    let kind: Kind
    let name: String
    let isStatic: Bool
    let parameters: [Parameter]
    let returns: TypeExpression
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
    /// Whose member it is, which says whether a host's member of the same shape takes its place.
    let origin: Origin
    /// Converts the receiver and the arguments, in declared order with defaults filled in, calls
    /// Swift, and converts back. An error it throws is the host's as it is: `body` makes it the
    /// member's (`Interpreter.hostFailure`). A member that changes its receiver gives the result and
    /// the changed receiver, which the caller puts back.
    let call: @Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value
    /// The member as a function a call binds its arguments to: `call`, with the error it throws one
    /// a script can catch, as a function's is.
    let body: FunctionBody
    /// What each parameter is, from `- Parameter name:` lines: `help`'s flags.
    var parameterDocs: [String: String] = [:]
    /// `async`: a call, or reading the property, needs `await`. Its glue
    /// waits in `suspend`, so other tasks run meanwhile.
    var effect: Effect = .sync
    /// `throws(Failure)`, for a generic parameter of its type: it throws
    /// unless that is `Never` (`Task<Int, Never>.value` doesn't).
    var typedThrows: String?

    init(
        kind: Kind,
        name: String,
        isStatic: Bool,
        parameters: [Parameter],
        returns: TypeExpression,
        generics: [Symbol.GenericParameter],
        isThrowing: Bool,
        isRethrowing: Bool,
        isMutating: Bool,
        attributes: [Symbol.Attribute] = [],
        summary: String,
        origin: Origin,
        typeName: String,
        call: @escaping @Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value,
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
        self.origin = origin
        self.call = call
        self.body = .native { interpreter, receiver, arguments in
            do { return try call(receiver, arguments) } catch {
                throw interpreter.hostFailure(error, in: "\(typeName).\(name)")
            }
        }
        self.parameterDocs = parameterDocs
    }
}

// MARK: Conversions the glue uses
