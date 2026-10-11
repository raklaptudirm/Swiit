import Foundation
import SwiitKit
import SystemPackage

/// Swift's own types and members, as Swish sees them: read from the
/// standard library's symbol graph (and swift-system's, for FilePath) by
/// `swiit-bridge`, which writes StandardLibrary.swift and SystemPackage.swift
/// beside this file (see `run bridge` in Tasks.swish
/// and Docs/Design/swift-interop.md). Each member comes with its signature,
/// for the checker, and its glue, which calls Swift.
@_spi(Host) public enum Bridge {
    /// The bridged types, by the name Swish writes them with.
    @_spi(Host) public nonisolated(unsafe) static let types: [String: BridgedType] = Dictionary(uniqueKeysWithValues: (standardLibrary + system + swiitKit + foundation + concurrency).map {
        ($0.name, $0.conforming(to: conformancesDeclaredHere[$0.name] ?? []))
    })

    /// Text as a value of the type named, if the type can be text and the
    /// text is one: through its failable initializer from text (`Int`), or
    /// as a text literal (`Character`, `FilePath`). A word on the command
    /// line, or a string literal where the type is wanted, is converted so.
    @_spi(Host) public static func value(of typeName: String, from text: String) -> Value?? {
        guard let type = types[typeName], type.parse != nil || type.literal != nil else { return nil }
        return .some(type.parse?(text) ?? type.literal?(text))
    }

    /// The bridged type Swish's type annotation is, and its generic
    /// parameters' bindings: `[Int]` is `Array` with Element Int.
    @_spi(Host) public static func type(of annotation: TypeAnnotation) -> (BridgedType, [String: TypeAnnotation])? {
        guard let (name, arguments) = annotation.swiftType, let type = types[name],
              type.genericParameters.count == arguments.count else { return nil }
        return (type, Dictionary(uniqueKeysWithValues: zip(type.genericParameters, arguments)))
    }
}

// Swift's rules for what text literals a type can be, picked the way Swift
// picks: by the most specific literal protocol it conforms to. A string
// literal is any text; a grapheme cluster literal, one Character; a
// Unicode scalar literal, one scalar.

@_spi(Swiit) public func textLiteral<T: ExpressibleByStringLiteral>(_: T.Type, _ text: String) -> T? where T.StringLiteralType == String {
    T(stringLiteral: text)
}

@_spi(Swiit) public func textLiteral<T: ExpressibleByExtendedGraphemeClusterLiteral>(_: T.Type, _ text: String) -> T?
where T.ExtendedGraphemeClusterLiteralType == Character {
    guard let character = text.first, text.dropFirst().isEmpty else { return nil }
    return T(extendedGraphemeClusterLiteral: character)
}

@_spi(Swiit) public func textLiteral<T: ExpressibleByUnicodeScalarLiteral>(_: T.Type, _ text: String) -> T?
where T.UnicodeScalarLiteralType == Unicode.Scalar {
    guard let scalar = text.unicodeScalars.first, text.unicodeScalars.dropFirst().isEmpty else { return nil }
    return T(unicodeScalarLiteral: scalar)
}

/// A bridged type's name as a value, as in `String(sub)` or `Int.max`.
@_spi(Host) public final class BridgedTypeName: SwiitObject, @unchecked Sendable {
    @_spi(Host) public let name: String
    @_spi(Host) public init(_ name: String) { self.name = name }
    @_spi(Host) public var typeName: String { "type" }
    @_spi(Host) public var memberNames: [String] { [] }
    @_spi(Host) public func member(_ name: String) -> Value? { nil }
    @_spi(Host) public var fields: Record? { nil }
    @_spi(Host) public var description: String { name }
}

@_spi(Host) public struct BridgedType {
    /// `String`, `Substring`, `Array`.
    @_spi(Host) public let name: String
    /// A generic type's parameters: `Element` for Array.
    @_spi(Host) public let genericParameters: [String]
    /// The protocols it conforms to, of those Swish knows, each with what
    /// its generic parameters must be for it: a ClosedRange is a Sequence
    /// when its Bound is Int (`["Bound": ["=Int"]]`).
    @_spi(Host) public let conformances: [String: [String: [String]]]
    /// Its associated types: `Element` is `Character` for String.
    @_spi(Host) public let associatedTypes: [String: TypeAnnotation]
    /// Text as one, through the type's failable initializer from text
    /// (`Int("42")`); nil if the text isn't one.
    @_spi(Host) public var parse: ((String) -> Value?)? = nil
    /// Text as one by Swift's rules for text literals (`Character`,
    /// `FilePath`); nil if the text can't be that literal.
    @_spi(Host) public var literal: ((String) -> Value?)? = nil
    /// Items as one, for a collection an array literal can be (Array, Set):
    /// what a parameter given several words gets.
    @_spi(Host) public var arrayLiteral: (([Value]) -> Value)? = nil
    @_spi(Host) public let members: [BridgedMember]


    /// It, conforming to `protocols` too, whatever its generic parameters are.
    func conforming(to protocols: [String]) -> BridgedType {
        guard !protocols.isEmpty else { return self }
        var all = conformances
        for name in protocols { all[name] = [:] }
        return BridgedType(name: name, genericParameters: genericParameters, conformances: all, associatedTypes: associatedTypes,
                           parse: parse, literal: literal, arrayLiteral: arrayLiteral, members: members)
    }

    @_spi(Host) public init(name: String, genericParameters: [String], conformances: [String: [String: [String]]], associatedTypes: [String: TypeAnnotation], parse: ((String) -> Value?)? = nil, literal: ((String) -> Value?)? = nil, arrayLiteral: (([Value]) -> Value)? = nil, members: [BridgedMember]) {
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

@_spi(Host) public struct BridgedMember {
    /// A setter is a property's other half, for `p.extension = "md"`.
    @_spi(Host) public enum Kind { case method, property, initializer, setter }

    @_spi(Host) public let kind: Kind
    @_spi(Host) public let name: String
    @_spi(Host) public let isStatic: Bool
    @_spi(Host) public let parameters: [Parameter]
    @_spi(Host) public let returns: TypeAnnotation
    @_spi(Host) public let generics: [String: [String]]
    @_spi(Host) public let isThrowing: Bool
    @_spi(Host) public let isRethrowing: Bool
    /// Changes its receiver, like `append`. Its glue gives the result and
    /// the changed receiver, which the shell puts back.
    @_spi(Host) public let isMutating: Bool
    /// `@discardableResult`, like `removeLast()`: a statement that's just
    /// the call doesn't show what it gives.
    @_spi(Host) public let discardableResult: Bool
    /// Its documentation's first paragraph, from Swift's: what `help` shows.
    @_spi(Host) public let summary: String
    /// Converts the arguments (and `self`), calls Swift, and converts back.
    @_spi(Host) public let body: FunctionBody
    /// What each parameter is, from `- Parameter name:` lines: `help`'s flags.
    @_spi(Host) public var parameterDocs: [String: String] = [:]
    /// `async`: a call, or reading the property, needs `await`. Its glue
    /// waits in `suspend`, so other tasks run meanwhile.
    @_spi(Host) public var effect: Effect = .sync
    /// `throws(Failure)`, for a generic parameter of its type: it throws
    /// unless that is `Never` (`Task<Int, Never>.value` doesn't).
    var typedThrows: String?

    @_spi(Host) public init(kind: Kind, name: String, isStatic: Bool, parameters: [Parameter], returns: TypeAnnotation, generics: [String: [String]], isThrowing: Bool, isRethrowing: Bool, isMutating: Bool, discardableResult: Bool, summary: String, body: FunctionBody, parameterDocs: [String: String] = [:], effect: Effect = .sync, typedThrows: String? = nil) {
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
        self.discardableResult = discardableResult
        self.summary = summary
        self.body = body
        self.parameterDocs = parameterDocs
    }
}

// MARK: Conversions the glue uses
