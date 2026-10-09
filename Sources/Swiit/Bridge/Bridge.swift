import Foundation
import SwishKit
import SystemPackage

/// Swift's own types and members, as Swish sees them: read from the
/// standard library's symbol graph (and swift-system's, for FilePath) by
/// `swiit-bridge`, which writes StandardLibrary.swift and SystemPackage.swift
/// beside this file (see `run bridge` in Tasks.swish
/// and Docs/Design/swift-interop.md). Each member comes with its signature,
/// for the checker, and its glue, which calls Swift.
@_spi(Shell) public enum Bridge {
    /// The bridged types, by the name Swish writes them with.
    @_spi(Shell) public nonisolated(unsafe) static let types: [String: BridgedType] = Dictionary(uniqueKeysWithValues: (standardLibrary + system + swishKit + foundation).map { ($0.name, $0) })

    /// Text as a value of the type named, if the type can be text and the
    /// text is one: through its failable initializer from text (`Int`), or
    /// as a text literal (`Character`, `FilePath`). A word on the command
    /// line, or a string literal where the type is wanted, is converted so.
    @_spi(Shell) public static func value(of typeName: String, from text: String) -> Value?? {
        guard let type = types[typeName], type.parse != nil || type.literal != nil else { return nil }
        return .some(type.parse?(text) ?? type.literal?(text))
    }

    /// The bridged type Swish's type annotation is, and its generic
    /// parameters' bindings: `[Int]` is `Array` with Element Int.
    @_spi(Shell) public static func type(of annotation: TypeAnnotation) -> (BridgedType, [String: TypeAnnotation])? {
        guard let (name, arguments) = annotation.swiftType, let type = types[name],
              type.genericParameters.count == arguments.count else { return nil }
        return (type, Dictionary(uniqueKeysWithValues: zip(type.genericParameters, arguments)))
    }
}

// Swift's rules for what text literals a type can be, picked the way Swift
// picks: by the most specific literal protocol it conforms to. A string
// literal is any text; a grapheme cluster literal, one Character; a
// Unicode scalar literal, one scalar.

@_spi(Shell) public func textLiteral<T: ExpressibleByStringLiteral>(_: T.Type, _ text: String) -> T? where T.StringLiteralType == String {
    T(stringLiteral: text)
}

@_spi(Shell) public func textLiteral<T: ExpressibleByExtendedGraphemeClusterLiteral>(_: T.Type, _ text: String) -> T?
where T.ExtendedGraphemeClusterLiteralType == Character {
    guard let character = text.first, text.dropFirst().isEmpty else { return nil }
    return T(extendedGraphemeClusterLiteral: character)
}

@_spi(Shell) public func textLiteral<T: ExpressibleByUnicodeScalarLiteral>(_: T.Type, _ text: String) -> T?
where T.UnicodeScalarLiteralType == Unicode.Scalar {
    guard let scalar = text.unicodeScalars.first, text.unicodeScalars.dropFirst().isEmpty else { return nil }
    return T(unicodeScalarLiteral: scalar)
}

/// A bridged type's name as a value, as in `String(sub)` or `Int.max`.
@_spi(Shell) public final class BridgedTypeName: SwishObject, @unchecked Sendable {
    @_spi(Shell) public let name: String
    @_spi(Shell) public init(_ name: String) { self.name = name }
    @_spi(Shell) public var typeName: String { "type" }
    @_spi(Shell) public var memberNames: [String] { [] }
    @_spi(Shell) public func member(_ name: String) -> Value? { nil }
    @_spi(Shell) public var fields: Record? { nil }
    @_spi(Shell) public var description: String { name }
}

@_spi(Shell) public struct BridgedType {
    /// `String`, `Substring`, `Array`.
    @_spi(Shell) public let name: String
    /// A generic type's parameters: `Element` for Array.
    @_spi(Shell) public let genericParameters: [String]
    /// The protocols it conforms to, of those Swish knows, each with what
    /// its generic parameters must be for it: a ClosedRange is a Sequence
    /// when its Bound is Int (`["Bound": ["=Int"]]`).
    @_spi(Shell) public let conformances: [String: [String: [String]]]
    /// Its associated types: `Element` is `Character` for String.
    @_spi(Shell) public let associatedTypes: [String: TypeAnnotation]
    /// Text as one, through the type's failable initializer from text
    /// (`Int("42")`); nil if the text isn't one.
    @_spi(Shell) public var parse: ((String) -> Value?)? = nil
    /// Text as one by Swift's rules for text literals (`Character`,
    /// `FilePath`); nil if the text can't be that literal.
    @_spi(Shell) public var literal: ((String) -> Value?)? = nil
    /// Items as one, for a collection an array literal can be (Array, Set):
    /// what a parameter given several words gets.
    @_spi(Shell) public var arrayLiteral: (([Value]) -> Value)? = nil
    @_spi(Shell) public let members: [BridgedMember]


    @_spi(Shell) public init(name: String, genericParameters: [String], conformances: [String: [String: [String]]], associatedTypes: [String: TypeAnnotation], parse: ((String) -> Value?)? = nil, literal: ((String) -> Value?)? = nil, arrayLiteral: (([Value]) -> Value)? = nil, members: [BridgedMember]) {
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

@_spi(Shell) public struct BridgedMember {
    /// A setter is a property's other half, for `p.extension = "md"`.
    @_spi(Shell) public enum Kind { case method, property, initializer, setter }

    @_spi(Shell) public let kind: Kind
    @_spi(Shell) public let name: String
    @_spi(Shell) public let isStatic: Bool
    @_spi(Shell) public let parameters: [Parameter]
    @_spi(Shell) public let returns: TypeAnnotation
    @_spi(Shell) public let generics: [String: [String]]
    @_spi(Shell) public let isThrowing: Bool
    @_spi(Shell) public let isRethrowing: Bool
    /// Changes its receiver, like `append`. Its glue gives the result and
    /// the changed receiver, which the shell puts back.
    @_spi(Shell) public let isMutating: Bool
    /// `@discardableResult`, like `removeLast()`: a statement that's just
    /// the call doesn't show what it gives.
    @_spi(Shell) public let discardableResult: Bool
    /// Its documentation's first paragraph, from Swift's: what `help` shows.
    @_spi(Shell) public let summary: String
    /// Converts the arguments (and `self`), calls Swift, and converts back.
    @_spi(Shell) public let body: FunctionBody
    /// What each parameter is, from `- Parameter name:` lines: `help`'s flags.
    @_spi(Shell) public var parameterDocs: [String: String] = [:]

    @_spi(Shell) public init(kind: Kind, name: String, isStatic: Bool, parameters: [Parameter], returns: TypeAnnotation, generics: [String: [String]], isThrowing: Bool, isRethrowing: Bool, isMutating: Bool, discardableResult: Bool, summary: String, body: FunctionBody, parameterDocs: [String: String] = [:]) {
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
