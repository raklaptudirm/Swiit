import Foundation
import SwiitKit

extension TypeChecker {
    // MARK: Calls

    func callType(_ callee: inout Expr, _ arguments: inout [Argument], expected: TypeAnnotation?) throws -> TypeAnnotation {
        // `Point(x: 1)`, `Level(rawValue: 2)`, `f(x)`.
        if case .variable(let name) = callee, let symbol = lookup(name) {
            switch symbol {
            case .structType:
                // What an extension adds goes after the type's own.
                guard let description = describe(named: name) else { break }
                let chosen = try resolve(description.initializers, &arguments, name: name)
                if let chosen, description.namesItsInitializers { callee = .chosen(callee, overload: chosen.index) }
                if let chosen, chosen.isThrowing { try throwingSite("\(name).init") }
                if let chosen { try effectSite(chosen.effect, "\(name).init") }
                return chosen?.returns ?? .named(name)
            case .enumType(let info):
                // An `init` the enum declares.
                if !info.initializers.isEmpty, !(arguments.count == 1 && arguments[0].label == "rawValue") {
                    let chosen = try resolve(info.initializers, &arguments, name: name)
                    if let chosen, info.initializers.count > 1 { callee = .chosen(callee, overload: chosen.index) }
                    if let chosen, chosen.isThrowing { try throwingSite("\(name).init") }
                    return chosen?.returns ?? .named(name)
                }
                guard arguments.count == 1, arguments[0].label == "rawValue" else {
                    throw TypeError("\(name) is made from a raw value: \(name)(rawValue: …)")
                }
                guard let rawType = info.rawType else { throw TypeError("\(name) has no raw values") }
                try expect(&arguments[0].value, rawType, "the raw value")
                return .optional(.named(name))
            case .functions(let overloads):
                return try call(overloads, callee: &callee, &arguments, name: name, expected: expected)
            case .swiftType(let typeName):
                // `String(sub)`: an initializer.
                let (type, bridgedExpr) = try bridgedCall(typeName, kind: .initializer, isStatic: true, receiver: nil, bindings: [:], name: "init", &arguments)
                callee = bridgedExpr
                return type
            default:
                break
            }
        }
        if case .member(.variable(let typeName), let name) = callee, case .swiftType? = lookup(typeName) {
            let (type, bridgedExpr) = try bridgedCall(typeName, kind: .method, isStatic: true, receiver: nil, bindings: [:], name: name, &arguments)
            callee = bridgedExpr
            return type
        }
        // `Point.make(1)`, `Level.make()`: a static method of a struct or an enum, its own or one an extension adds.
        if case .member(.variable(let typeName), let name) = callee, let symbol = lookup(typeName),
           { if case .structType = symbol { true } else if case .enumType = symbol { true } else { false } }(),
           case .methods(let methods, _)? = describe(named: typeName)?.staticMember(name) {
            return try callMember(methods, name, callee: &callee, &arguments)
        }
        // `x?.f()`: the method's result, or nil.
        if case .optionalMember(var baseExpr, let name) = callee {
            let wrapped = try optionalBase(&baseExpr)
            var member = Expr.member(.annotated(.literal(.nothing), .optional(wrapped)), name)
            let result = try methodCallType(wrapped, baseExpr: baseExpr, name, &member, &arguments)
            // A bridged method on nil is nil (runBridged checks).
            if case .bridged = member { callee = member } else { callee = .optionalMember(baseExpr, name) }
            if case .optional = result { return result }
            return result == .unknown || result == .void ? result : .optional(result)
        }
        if case .member(var baseExpr, let name) = callee {
            // `Result.failed(code: 2)`: a case with associated values.
            if case .variable(let typeName) = baseExpr, case .enumType(let info)? = lookup(typeName) {
                var payload: [Argument]? = arguments
                var wanted = TypeAnnotation.named(info.name)
                if case .generic(info.name, _)? = expected { wanted = expected! }
                let type = try caseType(name, &payload, expected: wanted)
                arguments = payload ?? []
                return type
            }
            let base = try typeOf(&baseExpr)
            callee = .member(baseExpr, name)
            try actorSite(base, baseExpr, name)
            return try methodCallType(base, baseExpr: baseExpr, name, &callee, &arguments)
        }
        // In a type's body, a call to a name that isn't bound may be to the type's own method.
        if case .variable(let name) = callee, lookup(name) == nil, case .variable(let selfType, _)? = lookup("self"), hasMember(selfType, named: name) {
            callee = .member(.variable("self"), name)
            return try callType(&callee, &arguments, expected: expected)
        }
        // `ls()` with no `ls`: a function that isn't there, not a variable.
        if case .variable(let name) = callee, lookup(name) == nil {
            throw TypeError("no function named '\(name)'")
        }
        let type = try typeOf(&callee)
        // `f(x)` where f's type has `callAsFunction`: that method is called.
        if case .named(let typeName) = type, let info = structInfo(named: typeName), info.declared.methods["callAsFunction"] != nil {
            var method = Expr.member(callee, "callAsFunction")
            let result = try callType(&method, &arguments, expected: expected)
            callee = method
            return result
        }
        if case .variable(let name) = callee { return try apply(type, &arguments, name: name) }
        return try apply(type, &arguments, name: "the function")
    }

    /// A call to a named function: the overload is chosen here.
    func call(_ overloads: [Signature], callee: inout Expr, _ arguments: inout [Argument], name: String, expected: TypeAnnotation? = nil) throws -> TypeAnnotation {
        calledByName(name)
        guard let chosen = try resolve(overloads, &arguments, name: name) else {
            // Which one isn't known until it runs (an argument isn't typed yet).
            return commonReturn(overloads)
        }
        if overloads.count > 1 { callee = .chosen(callee, overload: chosen.index) }
        // A body that names its type parameters is told what they are here.
        // What the call is used as says the rest (`let a: A = make()`).
        var solved = chosen.solved
        var returns = chosen.returns
        if let expected, let declared = overloads.first(where: { $0.index == chosen.index }), chosen.typeParameters.contains(where: { solved[$0] == nil }) {
            unify(declared.returns, expected, &solved)
            returns = substitute(declared.returns, solved)
        }
        let types = chosen.typeParameters.sorted().compactMap { parameter in
            solved[parameter].flatMap { $0 == .unknown ? nil : TypeArgument(name: parameter, type: $0) }
        }
        if !types.isEmpty { callee = .specialized(callee, types) }
        if chosen.isThrowing { try throwingSite("'\(name)'") }
        try effectSite(chosen.effect, "'\(name)'")
        // An optional chain's result is an optional, whatever the last link gives (`o?.a` of an `Int?` is an `Int?`).
        if chosen.flattensResult, case .optional(.optional(let inner)) = chosen.returns { return .optional(inner) }
        return returns
    }

    /// A call to one of a member's overloads: the one the arguments fit, what choosing it asks of the call (naming it to the
    /// interpreter when it has several, a change of the receiver, a `try`, an `await`), and what it gives back.
    func callMember(
        _ methods: [Signature], _ name: String, bindings: [String: TypeAnnotation] = [:], callee: inout Expr, _ arguments: inout [Argument],
        narrowing: Bool = true, mutating receiver: Expr? = nil
    ) throws -> TypeAnnotation {
        guard let chosen = try resolve(methods, &arguments, name: name, bindings: bindings) else { return commonReturn(methods) }
        if narrowing, methods.count > 1 { callee = .chosen(callee, overload: chosen.index) }
        if let receiver, chosen.isMutating { try checkMutable(receiver, method: name) }
        if chosen.isThrowing { try throwingSite("'\(name)'") }
        try effectSite(chosen.effect, "'\(name)'")
        return chosen.returns
    }

    @_spi(Layer) public func commonReturn(_ overloads: [Signature]) -> TypeAnnotation {
        overloads.allSatisfy { $0.returns == overloads[0].returns } ? overloads[0].returns : .unknown
    }

    /// `base.name(arguments)` for a receiver of type `base`; `baseExpr` is
    /// where it came from, if it can be changed by a mutating method.
    func methodCallType(
        _ written: TypeAnnotation, baseExpr: Expr?, _ name: String, _ callee: inout Expr, _ arguments: inout [Argument]
    ) throws -> TypeAnnotation {
        let base = erased(written)
        // `t.init()`, `t.make()` for a type held in a value (`T.Type`): what it is isn't known here, so not what it makes.
        if case .metatype(let made) = base {
            for index in arguments.indices { _ = try typeOf(&arguments[index].value, expecting: .unknown) }
            return name == "init" ? made : .unknown
        }
        // `self.init(x: 1)` in an initializer: another initializer makes the value.
        if name == "init", case .named(let structName) = base, structInfo(named: structName) != nil, let description = describe(base),
           lookup("$initializing") != nil {
            let candidates = description.initializers
            guard let chosen = try resolve(candidates, &arguments, name: "init") else { return .void }
            if candidates.count > 1, description.namesItsInitializers { callee = .chosen(callee, overload: chosen.index) }
            if chosen.isThrowing { try throwingSite("init") }
            return .void
        }
        // A method the type declares, a requirement of a protocol or the default an extension of it gives, or one an extension
        // adds to any type (`self` is the receiver, and a collection's items are known).
        if let description = describe(base), case .methods(let methods, let origin)? = description.instanceMember(name) {
            // A class's method is shared by every reference and a protocol's is any type's: no overload set of a value type's
            // own to name one of, and no value to change.
            let ofAValue = !(description.kind == .protocolType || origin == .declaration && description.isClass)
            let result = try callMember(methods, name, bindings: origin == .extensions ? elementBindings(for: base) : [:], callee: &callee, &arguments,
                                        narrowing: ofAValue, mutating: ofAValue ? baseExpr : nil)
            return description.kind == .protocolType ? substitute(result, [:]) : result
        }
        // Swift's own methods first; then what the prelude adds for shells,
        // like `sorted(by: \.size)`.
        var bridgedError: TypeError?
        if let (bridgedType, bindings) = bridged(base), bridgedType.members.contains(where: { $0.kind == .method && !$0.isStatic && $0.name == name }) {
            var attempt = arguments
            do {
                let (type, bridgedExpr) = try bridgedCall(bridgedType.name, kind: .method, isStatic: false, receiver: baseExpr,
                                                          bindings: bindings, name: name, &attempt)
                arguments = attempt
                callee = bridgedExpr
                return type
            } catch let error as TypeError {
                bridgedError = error
            }
        }
        do {
            if let sequenceResult = try sequenceMethodType(name, on: base, &callee, &arguments) {
                return sequenceResult
            }
        } catch let error as TypeError {
            throw TypeChecker.preferred(prelude: error, swift: bridgedError)
        }
        if let bridgedError { throw bridgedError }
        let member = try memberType(of: base, name)
        return try apply(member, &arguments, name: name)
    }

    /// Calling a value of type `type`.
    func apply(_ type: TypeAnnotation, _ arguments: inout [Argument], name: String) throws -> TypeAnnotation {
        switch type {
        case .functionType(let parameters, let result, let throwing, let effect):
            let signature = Signature(name: name, parameters: parameters.map { type -> Parameter in
                if case .inOut(let inner) = type { return Parameter(label: nil, name: "_", type: inner, isInout: true) }
                return Parameter(label: nil, name: "_", type: type)
            },
                                      returns: result, isThrowing: throwing, effect: effect)
            _ = try resolve([signature], &arguments, name: name)
            if throwing { try throwingSite(name) }
            try effectSite(effect, name)
            return result
        case .function, .unknown:
            for index in arguments.indices { _ = try typeOf(&arguments[index].value, expecting: .unknown) }
            return .unknown
        case .metatype:
            // `t(…)` for a type `t`: an initializer. What it makes isn't worked out here (a call checked again, once its
            // overload is chosen, comes this way too, and the initializer's own type was decided the first time).
            for index in arguments.indices { _ = try typeOf(&arguments[index].value, expecting: .unknown) }
            return .unknown
        case .any:
            throw TypeError("an Any can't be called: cast it first, as in (value as? (Int) -> Int)")
        default:
            throw TypeError("\(type) isn't a function")
        }
    }

    /// What `&place` may pass: a variable (or part of one) that can change.
    func checkPassable(_ place: Expr) throws {
        var root = place
        var throughMember = false
        while true {
            switch root {
            case .member(let inner, _): root = inner; throughMember = true
            case .index(let inner, _), .indexDefault(let inner, _, _), .forceUnwrap(let inner): root = inner
            case .variable(let name):
                // A member of a class instance is changed on the instance, whatever holds it.
                if throughMember, case .variable(.named(let typeName), _)? = lookup(name), structInfo(named: typeName)?.isClass == true { return }
                if case .variable(_, let mutable)? = lookup(name), !mutable {
                    throw TypeError("cannot pass '\(name)' as inout: it's a 'let' constant")
                }
                return
            default:
                throw TypeError("only a variable can be passed with &")
            }
        }
    }

    /// A mutating method changes its receiver, which must be a `var` (or
    /// part of one).
    func checkMutable(_ base: Expr, method: String) throws {
        var root = base
        var throughMember = false
        while true {
            switch root {
            case .member(let inner, _): root = inner; throughMember = true
            case .index(let inner, _), .indexDefault(let inner, _, _): root = inner
            case .forceUnwrap(let inner), .optionalMember(let inner, _): root = inner
            case .variable(let name):
                if throughMember, case .variable(.named(let typeName), _)? = lookup(name), structInfo(named: typeName)?.isClass == true { return }
                if case .variable(_, let mutable)? = lookup(name), !mutable {
                    throw TypeError("cannot use mutating method '\(method)' on '\(name)': it's a 'let' constant")
                }
                return
            default:
                throw TypeError("cannot use mutating method '\(method)' on a value that isn't in a variable")
            }
        }
    }
}

extension TypeChecker {
    /// When neither the prelude's method nor Swift's fits: the prelude's
    /// error, unless its overloads didn't even line up with the arguments
    /// (one was missing), when Swift's is the one that applies.
    @_spi(Layer) public static func preferred(prelude: TypeError, swift: TypeError?) -> TypeError {
        guard let swift, prelude.message.contains("missing") else { return prelude }
        return swift
    }
}
