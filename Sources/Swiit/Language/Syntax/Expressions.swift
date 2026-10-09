import Foundation
import SwishKit

@_spi(Shell) public struct RecordEntry: Equatable, Sendable {
    @_spi(Shell) public var key: Expr
    @_spi(Shell) public var value: Expr

    @_spi(Shell) public init(key: Expr, value: Expr) {
        self.key = key
        self.value = value
    }
}

/// A piece of a string: text, or an interpolated expression.
@_spi(Shell) public enum StringPart: Equatable, Sendable {
    case literal(String)
    case expression(Expr)
}

@_spi(Shell) public struct Argument: Equatable, Sendable {
    @_spi(Shell) public var label: String?
    @_spi(Shell) public var value: Expr

    @_spi(Shell) public init(label: String? = nil, value: Expr) {
        self.label = label
        self.value = value
    }
}

@_spi(Shell) public indirect enum Expr: Equatable, Sendable {
    /// `await j`, or `try await j`.
    @_spi(Shell) public var isAwait: Bool {
        switch self {
        case .await: true
        case .attempt(let inner, _): inner.isAwait
        default: false
        }
    }

    case literal(Value)
    case string([StringPart])
    case variable(String)
    /// Syntax a layer over the core adds: the shell's `$name`, `$(…)` and
    /// `async …` (Language/Syntax/SyntaxExtension.swift).
    case extended(ExprExtensionBox)
    /// `try expr`, `try? expr` or `try! expr`.
    case attempt(Expr, TryKind)
    /// `await job`, or a bare `await` for the most recent job. Under `try`
    /// (`throwing`), a job that failed throws.
    case await(Expr?, throwing: Bool)
    case list([Expr])
    case record([RecordEntry])
    case closure(ClosureLiteral)
    case call(Expr, [Argument])
    /// `value.name`: a record field, or a member like `count`.
    case member(Expr, String)
    /// `.directory` or `.failed(code: 2)`: a case whose enum comes from
    /// context, like the other side of `==` or a parameter's type.
    case caseLiteral(String, [Argument]?)
    case unary(UnaryOperator, Expr)
    case binary(BinaryOperator, Expr, Expr)
    case index(Expr, Expr)
    /// `(name: "x", 2)`: a tuple, labeled or not.
    case tuple([Argument])
    /// `let x: T = e`: the value, of the type written.
    case annotated(Expr, TypeAnnotation)
    /// `x!`: the optional's value; nil stops with an error.
    case forceUnwrap(Expr)
    /// `x?.name`: nil if `x` is, and its member otherwise.
    case optionalMember(Expr, String)
    /// `x?[i]`: nil if `x` is, and its element otherwise.
    case optionalIndex(Expr, Expr)
    /// A function, method or initializer, with the overload the checker
    /// chose: the candidate at that position. Only the checker makes these.
    case chosen(Expr, overload: Int)
    /// A member of a Swift type, bridged (Bridge.swift): the member the
    /// checker chose, by its position among its type's, with `self` if it
    /// isn't static. Only the checker makes these.
    case bridged(type: String, member: Int, receiver: Expr?, arguments: [Argument])
    /// `x as? T`, `x as! T`, `x is T`, or `x as T`.
    case cast(Expr, TypeAnnotation, CastKind)
    /// `#filePath`: the path of the script it's in.
    case filePath
    /// `if c { a } else { b }`, or `c ? a : b`: a value from one of two
    /// branches, each one expression (see `IfStatement.branchExpression`).
    case ifExpression(IfStatement)
    /// `\.size` or `\FileEntry.size`: a key path, its root type given or
    /// taken from context.
    case keyPath(root: String?, path: [String])
    /// A call returning Void, as a value: `()` once it's run, so `try?`
    /// can tell success (`()`) from failure (nil). Only the checker makes these.
    case voidValue(Expr)
}

@_spi(Shell) public enum TryKind: Equatable, Sendable {
    /// `try`: an error goes on to whatever handles it.
    case plain
    /// `try?`: nil instead of a runtime error.
    case optional
    /// `try!`: a runtime error stops the whole script, not just the line.
    case forced
}

@_spi(Shell) public enum CastKind: Equatable, Sendable {
    /// `as?`: the value as that type, or nil.
    case conditional
    /// `as!`: the value as that type, or an error.
    case forced
    /// `is`: whether it's that type.
    case check
    /// `as`: the same value, seen as a type it already fits.
    case upcast
}

@_spi(Shell) public enum UnaryOperator: String, Sendable {
    case not = "!"
    case negate = "-"
}

@_spi(Shell) public enum BinaryOperator: String, Sendable {
    case or = "||", and = "&&"
    case coalesce = "??"
    case equal = "==", notEqual = "!="
    case lessEqual = "<=", greaterEqual = ">=", less = "<", greater = ">"
    case closedRange = "...", halfOpenRange = "..<"
    case add = "+", subtract = "-"
    case multiply = "*", divide = "/", remainder = "%"
}
