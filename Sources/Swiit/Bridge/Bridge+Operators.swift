import Foundation
import SwishKit

/// Operators a bridged Swift type declares (`static func + (lhs: FileSize, rhs:
/// FileSize)`), used for operands of that type, as Swift does. Swish's own
/// Int, Double, String and Bool keep their operators in the shell, so the
/// bridge leaves out those the standard library declares.
extension Bridge {
    /// The members of the types of `typeNames` that are the operator
    /// `symbol` taking `arity` operands.
    static func operators(_ symbol: String, arity: Int, of typeNames: [String]) -> [BridgedMember] {
        var seen: Set<String> = []
        return typeNames.filter { seen.insert($0).inserted }.flatMap { name in
            (types[name]?.members ?? []).filter {
                $0.isStatic && $0.kind == .method && $0.name == symbol && $0.parameters.count == arity
            }
        }
    }
}

extension TypeChecker {
    /// What `left op right` is, if a bridged type of one of them declares an
    /// operator they fit: the one whose parameters are exactly their types,
    /// else the first they fit.
    func bridgedOperatorType(_ symbol: String, _ operands: [TypeAnnotation]) -> TypeAnnotation? {
        let candidates = Bridge.operators(symbol, arity: operands.count, of: operands.compactMap { $0.swiftType?.name })
        func fitting(_ member: BridgedMember) -> Bool {
            zip(operands, member.parameters).allSatisfy { fits($0, $1.type) }
        }
        let exact = candidates.first { member in zip(operands, member.parameters).allSatisfy { $0 == $1.type } }
        return (exact ?? candidates.first(where: fitting))?.returns
    }
}

extension Interpreter {
    /// Applies an operator a bridged type declares to its operands; nil if no
    /// operand's type declares one. A Swift operator that throws (an overflow)
    /// is an error here, with no `try`, as for Int.
    func bridgedOperator(_ symbol: String, _ operands: [Value]) throws -> Value? {
        let names = operands.compactMap { operand -> String? in
            if case .object(let box as SwiftValue) = operand { box.typeName } else { nil }
        }
        let functions = Bridge.operators(symbol, arity: operands.count, of: names).map {
            Function(name: symbol, parameters: $0.parameters, returnType: nil, body: $0.body)
        }
        guard !functions.isEmpty else { return nil }
        return try call(.function(OverloadSet(name: symbol, candidates: functions)), with: operands)
    }
}
