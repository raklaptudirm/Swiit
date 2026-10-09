import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Overloads

    /// The candidate a call uses, by Swift's rules: of those whose labels,
    /// defaults and types fit, the one whose parameters match the arguments
    /// most exactly. A tie is ambiguous, unless an argument's type isn't
    /// known yet, when nil leaves the choice to run time.
    @_spi(Shell) public func resolve(
        _ candidates: [Signature], _ arguments: inout [Argument], name: String, bindings: [String: TypeAnnotation] = [:]
    ) throws -> Signature? {
        var fitting: [(signature: Signature, cost: Int, uncertain: Bool, arguments: [Argument], sites: Int)] = []
        var firstError: TypeError?
        // Errors from the overloads the arguments line up with: if there's
        // one, it says what's wrong better than a list of candidates.
        var typeErrors: [TypeError] = []
        let sitesBefore = throwingSites
        for candidate in candidates {
            var attempt = arguments
            throwingSites = sitesBefore
            do {
                let (cost, uncertain, returns, throwing) = try match(&attempt, to: candidate, bindings: bindings)
                var resolved = candidate
                resolved.returns = returns
                resolved.isThrowing = throwing
                fitting.append((resolved, cost, uncertain, attempt, throwingSites))
            } catch let error as TypeError {
                firstError = firstError ?? error
                if !error.isArity { typeErrors.append(error) }
            }
        }
        throwingSites = sitesBefore
        guard let best = fitting.map(\.cost).min() else {
            if candidates.count == 1, let firstError { throw firstError }
            if typeErrors.count == 1 { throw typeErrors[0] }
            let list = candidates.map { "  " + describe($0) }
            throw TypeError("\(name): no overload accepts these arguments; candidates:\n" + list.joined(separator: "\n"))
        }
        let winners = fitting.filter { $0.cost == best }
        if winners.count > 1 {
            if winners.contains(where: \.uncertain) { return nil }
            throw TypeError("\(name): ambiguous call; these overloads all match:\n"
                            + winners.map { "  " + describe($0.signature) }.joined(separator: "\n"))
        }
        arguments = winners[0].arguments
        throwingSites = winners[0].sites
        return winners[0].signature
    }

    @_spi(Shell) public func describe(_ signature: Signature) -> String {
        "\(signature.name)(" + signature.parameters.map { "\($0.label ?? "_"): \($0.type)" }.joined(separator: ", ") + ")"
    }

    /// Matches `arguments` to `signature`'s parameters by Swift's rules for
    /// labels, defaults, variadics and trailing closures. The cost counts
    /// conversions (a literal Int as a Double, a value made optional, an
    /// Output as its text) and untyped parameters, which match anything.
    @_spi(Shell) public func match(
        _ arguments: inout [Argument], to signature: Signature, bindings initial: [String: TypeAnnotation]
    ) throws -> (cost: Int, uncertain: Bool, returns: TypeAnnotation, throws: Bool) {
        let name = signature.name
        var cost = 0
        var uncertain = false
        var index = 0
        // Type parameters, bound as arguments show what they are.
        var bindings = initial
        var argumentsThrow = false
        func take(_ parameter: Parameter) throws {
            let natural = TypeChecker.hasNaturalType(arguments[index].value) ? try typeOf(&arguments[index].value) : nil
            let isLiteral = if case .literal = arguments[index].value { true } else { false }
            let wanted = substitute(parameter.type, bindings)
            let actual = try typeOf(&arguments[index].value, expecting: wanted)
            guard fits(actual, wanted) else {
                throw TypeError("\(name): '\(parameter.name)' must be \(wanted), not \(actual)")
            }
            unify(parameter.type, actual, &bindings)
            if case .functionType(_, _, true) = actual { argumentsThrow = true }
            switch (natural, wanted) {
            case (.unknown?, _): uncertain = true
            case (_, .any), (_, .unknown), (_, .function), (_, .record): cost += 3
            // A literal made into another type than its own (`"x"` as a
            // Character) ranks below one taken as it is, as in Swift:
            // `String("x")` takes the String.
            case (let type?, _) where isLiteral && actual != type: cost += 2
            // A generic sequence is less specific than a concrete type, as
            // Swift ranks them: `merging([:])` takes the dictionary one.
            case (_, .someSequence): cost += 1
            case (let type?, let wanted) where type != wanted: cost += 1
            default: break
            }
            index += 1
        }
        for (position, parameter) in signature.parameters.enumerated() {
            let later = signature.parameters[(position + 1)...]
            let trailing = index == arguments.count - 1 && arguments[index].label == nil && parameter.label != nil
                && later.allSatisfy { $0.label != nil } && parameter.type.acceptsFunction
                && { if case .closure = arguments[index].value { true } else { false } }()
            if index < arguments.count, arguments[index].label == parameter.label || trailing {
                if parameter.variadic {
                    repeat { try take(parameter) } while index < arguments.count && arguments[index].label == nil
                } else {
                    try take(parameter)
                }
            } else if parameter.variadic || parameter.hasDefault {
                continue
            } else {
                let label = parameter.label.map { "'\($0):'" } ?? "#\(position + 1)"
                var error = TypeError("\(name): missing argument \(label)")
                error.isArity = true
                throw error
            }
        }
        guard index == arguments.count else {
            let extra = arguments[index].label.map { "'\($0):'" } ?? "#\(index + 1)"
            var error = TypeError("\(name): unexpected argument \(extra)")
            error.isArity = true
            throw error
        }
        for (parameter, protocols) in signature.generics {
            guard let bound = bindings[parameter], bound != .unknown else { continue }
            for proto in protocols where !conforms(bound, to: proto) {
                throw TypeError("\(name) needs \(parameter) to be \(proto.hasPrefix("=") ? String(proto.dropFirst()) : proto), and \(bound) isn't")
            }
        }
        let throwing = signature.isThrowing || signature.isRethrowing && argumentsThrow
        return (cost, uncertain, substitute(signature.returns, bindings), throwing)
    }

    /// Whether an argument has a type of its own, apart from context: not a
    /// closure, a `.case`, `nil` or a collection literal, which take theirs
    /// from the parameter.
    @_spi(Shell) public static func hasNaturalType(_ expr: Expr) -> Bool {
        switch expr {
        case .closure, .caseLiteral, .list, .record, .tuple, .literal(.nothing), .keyPath: false
        // `c ? .green : .red` takes its type from where it goes, as its branches do.
        case .ifExpression(let node): branches(of: node).allSatisfy(hasNaturalType)
        default: true
        }
    }
}
