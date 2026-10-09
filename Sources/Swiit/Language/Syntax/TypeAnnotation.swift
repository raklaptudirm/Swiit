import Foundation
import SwishKit

/// A type, as written in a declaration and as the checker works it out.
@_spi(Shell) public indirect enum TypeAnnotation: Hashable, Sendable, CustomStringConvertible {
    case any, bool, int, double, string
    /// A record whose fields aren't known: a builtin's row, until the
    /// builtins declare their types.
    case record
    /// `()`: what a function without `->` returns.
    case void
    /// A struct or enum, declared in Swish or by the shell, like `FileType`.
    case named(String)
    case list(TypeAnnotation)
    /// `[K: V]`.
    case dictionary(TypeAnnotation, TypeAnnotation)
    /// `(name: String, Int)`.
    case tuple([TupleElement])
    /// A generic parameter, like `Element` or `T` in a builtin's signature.
    case parameter(String)
    /// `KeyPath<Root, Value>`, what `\.size` is.
    case keyPath(TypeAnnotation, TypeAnnotation)
    /// Any function: a closure whose signature isn't known yet.
    case function
    /// `(Int, String) -> Bool`, or `(Int) throws -> Bool`.
    case functionType([TypeAnnotation], TypeAnnotation, throws: Bool = false)
    /// `T?`: a T, or nil.
    case optional(TypeAnnotation)
    /// A generic Swift type Swish holds as it is: `Set<Int>`, `ClosedRange<Int>`.
    case generic(String, [TypeAnnotation])
    /// What a Swift parameter `S: Sequence` with `S.Element == E` takes:
    /// any sequence of E, as `some Sequence<E>` says.
    case someSequence(TypeAnnotation)
    /// Not known yet: what a program prints, or a builtin that hasn't
    /// declared its type. It fits anywhere, and anything fits it.
    case unknown

    @_spi(Shell) public struct TupleElement: Hashable, Sendable {
        @_spi(Shell) public var label: String?
        @_spi(Shell) public var type: TypeAnnotation
    
        @_spi(Shell) public init(label: String? = nil, type: TypeAnnotation) {
            self.label = label
            self.type = type
        }
    }

    @_spi(Shell) public var description: String { AttributedString(joining: styled).text }

    /// As Swift writes it, in pieces by what each is (the name of a type, a
    /// label, a keyword, or punctuation), so help can color it and no one has
    /// to read the text back to find out.
    @_spi(Shell) public var styled: [AttributedString] {
        func name(_ text: String) -> AttributedString { .init(text, .type) }
        func punctuation(_ text: String) -> AttributedString { .init(text) }
        func list(_ items: [[AttributedString]]) -> [AttributedString] {
            items.enumerated().flatMap { index, item in (index > 0 ? [punctuation(", ")] : []) + item }
        }
        switch self {
        case .any: return [name("Any")]
        case .bool: return [name("Bool")]
        case .int: return [name("Int")]
        case .double: return [name("Double")]
        case .string: return [name("String")]
        case .record: return [name("Record")]
        case .void: return [name("Void")]
        case .list(let element): return [punctuation("[")] + element.styled + [punctuation("]")]
        case .dictionary(let key, let value):
            return [punctuation("[")] + key.styled + [punctuation(": ")] + value.styled + [punctuation("]")]
        case .tuple(let elements):
            return [punctuation("(")] + list(elements.map { element in
                (element.label.map { [AttributedString($0, .variable), punctuation(": ")] } ?? []) + element.type.styled
            }) + [punctuation(")")]
        case .function: return [name("function")]
        case .functionType(let parameters, let result, let throwing):
            return [punctuation("(")] + list(parameters.map(\.styled)) + [punctuation(")")]
                + (throwing ? [punctuation(" "), .init("throws", .keyword)] : []) + [punctuation(" -> ")] + result.styled
        case .named(let text), .parameter(let text): return [name(text)]
        case .generic(let text, let arguments): return [name(text), punctuation("<")] + list(arguments.map(\.styled)) + [punctuation(">")]
        case .someSequence(let element):
            return [.init("some", .keyword), punctuation(" "), name("Sequence"), punctuation("<")] + element.styled + [punctuation(">")]
        case .keyPath(let root, let value):
            return [name("KeyPath"), punctuation("<")] + root.styled + [punctuation(", ")] + value.styled + [punctuation(">")]
        case .optional(let wrapped):
            if case .functionType = wrapped { return [punctuation("(")] + wrapped.styled + [punctuation(")?")] }
            return wrapped.styled + [punctuation("?")]
        case .unknown: return [punctuation("_")]
        }
    }
}

extension TypeAnnotation {
    /// Swift's types that Swish writes with an annotation of its own, by
    /// name: one table for the parser (`Int` is `.int`) and for finding the
    /// Swift type an annotation is (`.int` is `Int`). The generic ones are
    /// sugar: `[T]`, `T?`, `[K: V]`.
    /// What `$(…)` gives: a command's output, which is a Swift type like any
    /// other, held as it is.
    @_spi(Shell) public static let output = TypeAnnotation.named("Output")

    private static let spelled: [(name: String, make: @Sendable ([TypeAnnotation]) -> TypeAnnotation?)] = [
        ("Int", { $0.isEmpty ? .int : nil }), ("Double", { $0.isEmpty ? .double : nil }),
        ("String", { $0.isEmpty ? .string : nil }), ("Bool", { $0.isEmpty ? .bool : nil }),
        ("Record", { $0.isEmpty ? .record : nil }),
        ("Output", { $0.isEmpty ? .output : nil }),
        ("Any", { $0.isEmpty ? .any : nil }), ("Value", { $0.isEmpty ? .any : nil }), ("Void", { $0.isEmpty ? .void : nil }),
        ("Array", { $0.count == 1 ? .list($0[0]) : nil }),
        ("Optional", { $0.count == 1 ? .optional($0[0]) : nil }),
        ("Dictionary", { $0.count == 2 ? .dictionary($0[0], $0[1]) : nil }),
    ]

    /// The annotation Swish writes `name<arguments>` with, if it has one of
    /// its own: `Int`, `Array<Int>` as `[Int]`.
    @_spi(Shell) public static func spelled(_ name: String, _ arguments: [TypeAnnotation] = []) -> TypeAnnotation? {
        spelled.lazy.compactMap { $0.name == name ? $0.make(arguments) : nil }.first
    }

    /// The Swift type this annotation stands for, by name, with its generic
    /// arguments: `.int` is `Int`, `[String]` is `Array<String>`. The
    /// inverse of `spelled`; nil for one that doesn't name a type.
    @_spi(Shell) public var swiftType: (name: String, arguments: [TypeAnnotation])? {
        switch self {
        case .named(let name): return (name, [])
        case .generic(let name, let arguments): return (name, arguments)
        case .list(let element): return ("Array", [element])
        case .optional(let wrapped): return ("Optional", [wrapped])
        case .dictionary(let key, let value): return ("Dictionary", [key, value])
        default:
            return TypeAnnotation.spelled.first { $0.make([]) == self }.map { ($0.name, []) }
        }
    }
}

