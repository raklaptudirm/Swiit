import SwishKit

/// Syntax the core's grammar doesn't define: what a layer over the core adds,
/// like the shell's commands, pipelines and substitutions. The tree holds it
/// without knowing what it is, and the checker asks it to check itself; then
/// the layer rewrites it into the core's own tree (as the shell's `Desugarer`
/// does), so the interpreter only ever runs Swift. The core never names the
/// node types, so it can be built without them (Docs/Design/frontend.md).
@_spi(Shell) public protocol SyntaxExtension: Sendable {
    /// Trees compare, so extensions do.
    func isEqual(to other: any SyntaxExtension) -> Bool
}

extension SyntaxExtension where Self: Equatable {
    @_spi(Shell) public func isEqual(to other: any SyntaxExtension) -> Bool {
        (other as? Self) == self
    }
}

/// An expression an extension adds: `$(…)`, `$name`, `async …`, a command or
/// commands joined by `|`, `&&` and `||`.
@_spi(Shell) public protocol ExprExtension: SyntaxExtension {
    /// Checks it, with whatever the checker found written in, and gives its type.
    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation
    /// Whether it ends the program (`exit`), for a guard's `else`, which must
    /// leave.
    var leavesProgram: Bool { get }
}

extension ExprExtension {
    @_spi(Shell) public var leavesProgram: Bool { false }
}

/// A statement an extension adds: `env.NAME = value`, `import Name from path`.
@_spi(Shell) public protocol StatementExtension: SyntaxExtension {
    mutating func check(in checker: TypeChecker) throws
}

extension RuntimeError {
    /// A layer's construct that reached the interpreter, which only runs Swift.
    static let unrewritten = RuntimeError("a construct from a layer over the core must be rewritten into Swift before it runs")
}

/// What the tree holds for each: the node, compared through `isEqual`.
@_spi(Shell) public struct ExprExtensionBox: Equatable, Sendable {
    @_spi(Shell) public var node: any ExprExtension

    @_spi(Shell) public init(_ node: any ExprExtension) {
        self.node = node
    }

    @_spi(Shell) public static func == (lhs: ExprExtensionBox, rhs: ExprExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}

@_spi(Shell) public struct StatementExtensionBox: Equatable, Sendable {
    @_spi(Shell) public var node: any StatementExtension

    @_spi(Shell) public init(_ node: any StatementExtension) {
        self.node = node
    }

    @_spi(Shell) public static func == (lhs: StatementExtensionBox, rhs: StatementExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}
