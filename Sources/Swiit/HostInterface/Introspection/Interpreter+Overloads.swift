import Foundation
import SwiftSyntax
import Synchronization

// Choosing among the overloads of a function.

extension Interpreter {
    func overload(
        among candidates: [Symbol],
        arguments: [ScriptType.Element]
    ) throws(Diagnostic) -> Symbol {
        guard !candidates.isEmpty else {
            throw Diagnostic(kind: .type, message: "there is nothing to call")
        }
        let checker = TypeChecker(interpreter: self)
        func penalty(_ candidate: Symbol) -> Int? {
            guard let parameters = candidate.function?.parameters else { return nil }
            var cost = 0
            var next = 0
            var given: Set<String> = []
            for argument in arguments {
                // The parameter this argument is for: by label, else the next without one.
                guard
                    let index = parameters[next...]
                        .firstIndex(where: { $0.label == argument.label })
                        ?? parameters.firstIndex(where: {
                            $0.arity == .variadic && $0.label == argument.label
                        })
                else { return nil }
                let parameter = parameters[index]
                // A function of a signature not known fits where any function is wanted.
                guard var actual = annotation(argument.type),
                    let expected = parameter.annotation ?? annotation(parameter.type)
                else { return nil }
                if actual == .function { actual = .unknown }
                guard checker.fits(actual, expected) else { return nil }
                if expected == .any || expected == .unknown { cost += 1 }
                given.insert(parameter.name)
                next = parameter.arity == .variadic ? index : index + 1
            }
            // What is left out must have a default.
            for parameter in parameters
            where !given.contains(parameter.name) && parameter.arity == .required { return nil }
            return cost
        }
        let fitting = candidates.compactMap { candidate in
            penalty(candidate).map { (candidate, $0) }
        }
        guard let best = fitting.map(\.1).min() else {
            let shown = arguments.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }
                .joined(separator: ", ")
            throw Diagnostic(
                kind: .type,
                message: "\(candidates[0].name): no overload accepts (\(shown))"
            )
        }
        let winners = fitting.filter { $0.1 == best }
        guard winners.count == 1 else {
            throw Diagnostic(
                kind: .type,
                message: "\(candidates[0].name): ambiguous call; \(winners.count) overloads match"
            )
        }
        return winners[0].0
    }
}
