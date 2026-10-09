@_spi(Shell) import Swiit
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// A front end on SwiftSyntax: SwiftParser reads the source, and the tree it
/// gives is lowered to the core's. What it doesn't lower yet is an error that
/// names the construct, so the supported subset is the set of nodes lowered.
@_spi(Shell) public struct SwiftSyntaxFrontEnd: SyntaxFrontEnd {
    @_spi(Shell) public init() {}

    @_spi(Shell) public func parse(_ source: String, bound: [String: NameKind], plugin: (any SyntaxPlugin)?) throws(SyntaxError) -> Program {
        if plugin != nil { throw SyntaxError("this front end doesn't read a layer's syntax yet") }
        let parsed = Parser.parse(source: source)
        var errors: [Error] = []
        let folded = OperatorTable.standardOperators.foldAll(parsed) { errors.append($0) }
        if let error = errors.first { throw SyntaxError("\(error)") }
        guard let tree = folded.as(SourceFileSyntax.self) else { throw SyntaxError("not a source file") }
        var lowering = Lowering(source: source, tree: tree, bound: bound)
        do {
            return try lowering.program()
        } catch let error as SyntaxError {
            throw error
        } catch {
            throw SyntaxError("\(error)")
        }
    }
}
