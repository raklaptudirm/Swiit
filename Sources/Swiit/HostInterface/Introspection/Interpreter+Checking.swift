import Foundation
import SwiftSyntax
import Synchronization

// Checking source without running it: its declarations and the type of an expression.

extension Interpreter {
    /// Checks a program as `evaluate` would, and stops there: nothing runs, so a mistake is found
    /// before any statement's effect happens. It says what the program declares at its top level
    /// (its functions, types and variables), which a host can check its own uses against.
    public func check(_ source: String) throws(Diagnostic) -> Declarations {
        do {
            return try inCurrentTask { () throws -> Declarations in
                switch parse(source) {
                case .failure(let error):
                    throw Diagnostic(
                        kind: .syntax(isIncomplete: error.incomplete),
                        message: error.description,
                        range: error.range
                    )
                case .success(let program):
                    let checker = TypeChecker(interpreter: self)
                    do {
                        _ = try checker.check(program)
                    } catch let error as TypeError {
                        throw Diagnostic(
                            kind: .type,
                            message: error.message,
                            range: error.spot ?? error.range
                                ?? error.line.map { SourceRange(line: $0) }
                        )
                    }
                    // The doc comments of the functions it declares, in the order it declares them.
                    var docs: [String: [Documentation]] = [:]
                    for case .function(let decl) in program.statements {
                        docs[decl.name, default: []]
                            .append(
                                decl.documentation ?? Documentation(summary: "", parameters: [:])
                            )
                    }
                    var declarations = Declarations(
                        symbols: checker.scopes[0].sorted { $0.key < $1.key }
                            .flatMap { declaredSymbols(of: $0.key, $0.value) }
                            .map { symbol in
                                guard case .function(var function) = symbol.kind,
                                    var queue = docs[symbol.name],
                                    !queue.isEmpty
                                else { return symbol }
                                let documentation = queue.removeFirst()
                                docs[symbol.name] = queue
                                var documented = symbol
                                documented.summary =
                                    documentation.summary.isEmpty ? nil : documentation.summary
                                function.parameters = function.parameters.map {
                                    var p = $0
                                    p.documentation = documentation.parameters[p.name]
                                    return p
                                }
                                documented.kind = .function(function)
                                return documented
                            }
                    )
                    // What each type it declares has, which does not exist to ask yet: an enum's
                    // cases, with the raw values it writes or Swift gives them.
                    var rawValues: [String: [String: Value]] = [:]
                    for case .enumDecl(let decl) in program.statements {
                        rawValues[decl.name] = Interpreter.rawValues(of: decl)
                    }
                    for (name, symbol) in checker.scopes[0] {
                        switch symbol {
                        case .structType, .enumType:
                            declarations.members[name] = memberSymbols(
                                named: nil,
                                of: .named(name),
                                checker: checker,
                                rawValues: rawValues
                            )
                        default: break
                        }
                    }
                    return declarations
                }
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// What a checked program declares at its top level.
    public struct Declarations: Sendable {
        /// Its functions, types and variables.
        public var symbols: [Symbol]
        /// What each struct and enum it declares has, by the type's name: its members, its
        /// initializers and an enum's cases, for reading a word against an enum before it exists.
        public var members: [String: [Symbol]] = [:]
    }

    /// The type of an expression written at the top level: the globals are in scope, a script's
    /// locals are not.
    public func scriptType(ofExpression expression: String) throws(Diagnostic) -> ScriptType {
        do {
            return try withMainTask { () throws -> ScriptType in
                switch parse(expression) {
                case .failure(let error):
                    throw Diagnostic(
                        kind: .syntax(isIncomplete: error.incomplete),
                        message: error.description,
                        range: error.range
                    )
                case .success(let program):
                    guard program.statements.count == 1,
                        case .expression(var expr) = program.statements[0]
                    else {
                        throw Diagnostic(
                            kind: .type,
                            message: "scriptType(of:) takes one expression"
                        )
                    }
                    do {
                        return scriptType(try TypeChecker(interpreter: self).typeOf(&expr))
                    } catch let error as TypeError {
                        throw Diagnostic(
                            kind: .type,
                            message: error.message,
                            range: error.spot ?? error.range
                                ?? error.line.map { SourceRange(line: $0) }
                        )
                    }
                }
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }
}
