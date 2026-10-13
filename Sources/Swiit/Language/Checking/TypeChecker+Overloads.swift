import Foundation
import SwiitKit

extension TypeChecker {
    // MARK: Overloads

    /// The candidate a call uses, by Swift's rules: of those whose labels,
    /// defaults and types fit, the one whose parameters match the arguments
    /// most exactly. A tie is ambiguous, unless an argument's type isn't
    /// known yet, when nil leaves the choice to run time.
    @_spi(Layer) public func resolve(
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
        if winners.count > 1, !winners.contains(where: \.uncertain), let specific = mostSpecific(winners.map(\.signature)),
           let position = winners.firstIndex(where: { $0.signature.index == specific.index }) {
            arguments = winners[position].arguments
            throwingSites = winners[position].sites
            lastThrown = winners[position].signature.thrownType
            return winners[position].signature
        }
        if winners.count > 1 {
            if winners.contains(where: \.uncertain) { return nil }
            throw TypeError("\(name): ambiguous call; these overloads all match:\n"
                            + winners.map { "  " + describe($0.signature) }.joined(separator: "\n"))
        }
        arguments = winners[0].arguments
        throwingSites = winners[0].sites
        lastThrown = winners[0].signature.thrownType
        return winners[0].signature
    }

    /// Of overloads that all fit, the one Swift prefers: with fewer generic parameters, or constraints that
    /// refine the others' (`T: P3` over `T: P1` when P3 takes in P1).
    func mostSpecific(_ candidates: [Signature]) -> Signature? {
        func genericCount(_ signature: Signature) -> Int {
            func count(_ type: TypeAnnotation) -> Int {
                switch type {
                case .parameter: 1
                case .list(let e), .optional(let e), .someSequence(let e), .inOut(let e): count(e)
                case .dictionary(let k, let v): count(k) + count(v)
                case .generic(_, let arguments): arguments.map(count).reduce(0, +)
                case .functionType(let parameters, let result, _, _): parameters.map(count).reduce(0, +) + count(result)
                case .tuple(let elements): elements.map { count($0.type) }.reduce(0, +)
                default: 0
                }
            }
            return signature.parameters.map { count($0.type) }.reduce(0, +)
        }
        let fewest = candidates.map(genericCount).min()!
        let narrowed = candidates.filter { genericCount($0) == fewest }
        if narrowed.count == 1 { return narrowed[0] }
        // `a` refines `b` when each of b's constraints is among what a's constraints take in.
        func refines(_ a: Signature, _ b: Signature) -> Bool {
            b.generics.allSatisfy { parameter, protocols in
                let have = Set((a.generics[parameter] ?? []).flatMap(protocolClosure))
                return protocols.allSatisfy { have.contains($0) }
            }
        }
        let best = narrowed.filter { a in narrowed.allSatisfy { b in refines(a, b) } }
        // Equal in every way is no preference.
        guard best.count == 1 else { return nil }
        return best[0]
    }

    func describe(_ signature: Signature) -> String {
        "\(signature.name)(" + signature.parameters.map { "\($0.label ?? "_"): \($0.type)" }.joined(separator: ", ") + ")"
    }

    /// Matches `arguments` to `signature`'s parameters by Swift's rules for
    /// labels, defaults, variadics and trailing closures. The cost counts
    /// conversions (a literal Int as a Double, a value made optional, an
    /// Output as its text) and untyped parameters, which match anything.
    func match(
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
            let passed = if case .inoutArgument = arguments[index].value { true } else { false }
            if parameter.isInout && !passed {
                throw TypeError("\(name): '\(parameter.name)' is inout: pass it as &\(parameter.name)")
            }
            if !parameter.isInout && passed {
                throw TypeError("\(name): '\(parameter.name)' isn't inout, so it can't be passed with &")
            }
            // `@autoclosure`: the argument is the closure's result, and is made a closure.
            if parameter.isAutoclosure, case .functionType(let closureParameters, _, _, _) = parameter.type, closureParameters.isEmpty {
                if case .closure = arguments[index].value {} else {
                    arguments[index].value = .closure(ClosureLiteral(
                        parameters: [], body: Program(statements: [.expression(arguments[index].value)])))
                }
            }
            // `@Builder content: () -> V`: a closure given for it is made by the builder.
            if let builder = parameter.resultBuilder, case .closure(var literal) = arguments[index].value, literal.builtBy == nil {
                literal.body = try resultBuilt(literal.body, by: builder)
                literal.builtBy = builder
                arguments[index].value = .closure(literal)
            }
            let natural = TypeChecker.hasNaturalType(arguments[index].value) ? try typeOf(&arguments[index].value) : nil
            let isLiteral = if case .literal = arguments[index].value { true } else { false }
            let wanted = substitute(parameter.type, bindings)
            let actual = try typeOf(&arguments[index].value, expecting: wanted)
            guard fits(actual, wanted) else {
                throw TypeError("\(name): '\(parameter.name)' must be \(wanted), not \(actual)")
            }
            unify(parameter.type, actual, &bindings)
            // `print(x)` shows an optional as Swift does, which the type says.
            if name == "print", parameter.type == .any, parameter.variadic, TypeChecker.isShownByType(actual) {
                arguments[index].value = .described(arguments[index].value, actual)
            }
            if case .functionType(_, _, true, _) = actual { argumentsThrow = true }
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
            default:
                // A closure that doesn't throw takes the overload whose
                // parameter doesn't either, as Swift ranks them: `Task { 1 }`
                // is a `Task<Int, Never>`.
                if case .functionType(_, _, false, _) = actual, case .functionType(_, _, true, _) = wanted { cost += 1 }
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
    static func hasNaturalType(_ expr: Expr) -> Bool {
        switch expr {
        case .closure, .caseLiteral, .list, .record, .tuple, .literal(.nothing), .keyPath: false
        // `c ? .green : .red` takes its type from where it goes, as its branches do.
        case .ifExpression(let node): branches(of: node).allSatisfy(hasNaturalType)
        default: true
        }
    }
}
