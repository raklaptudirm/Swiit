import Foundation

extension TypeChecker {
    /// A generic enum's type arguments say what its cases hold, and nothing else: its values are
    /// its name.
    func erasedName(_ type: TypeExpression) -> String? {
        if let name = (erased(type).plainName) { name } else { nil }
    }

    func erased(_ type: TypeExpression) -> TypeExpression {
        if let (name, _) = type.genericParts, enumInfo(named: name) != nil { return .named(name) }
        if let element = type.arrayElement { return .list(erased(element)) }
        if let wrapped = type.optionalWrapped { return .optional(erased(wrapped)) }
        if let (key, value) = type.dictionaryTypes {
            return .dictionary(erased(key), erased(value))
        }
        return type
    }

    // MARK: Fitting

    /// Whether a value of type `actual` can be used where `expected` is.
    func fits(_ actual: TypeExpression, _ expected: TypeExpression) -> Bool {
        let actual = erased(actual), expected = erased(expected)
        if actual == expected || actual == .unknown || expected == .unknown || expected == .any {
            return true
        }
        // A protocol's type is any type that conforms to it.
        if let protocolName = expected.plainName, protocolInfo(named: protocolName) != nil {
            // A host type with what it holds is that type (`Job<Int>` is a `Job`).
            if actual.genericParts?.name == protocolName { return true }
            if actual.isNominal { return conforms(actual, to: protocolName) }
        }
        if let a = actual.optionalWrapped, let b = expected.optionalWrapped { return fits(a, b) }
        if case .metatype(let a) = actual, case .metatype(let b) = expected {
            return fits(a.instance, b.instance)
        }
        if let wrapped = expected.optionalWrapped { return fits(actual, wrapped) }
        if let a = actual.arrayElement, let b = expected.arrayElement { return fits(a, b) }
        if let (ak, av) = actual.dictionaryTypes, let (bk, bv) = expected.dictionaryTypes {
            return fits(ak, bk) && fits(av, bv)
        }
        if let (a, aa) = actual.genericParts, let (b, ba) = expected.genericParts {
            return a == b && aa.count == ba.count && zip(aa, ba).allSatisfy { fits($0, $1) }
        }
        // An Error is any of the types that conform to it, as a protocol's type is.
        if let a = actual.plainName, expected.plainName == "Error",
            conforms(.named(a), to: "Error")
        {
            return true
        }
        // A host type with what it holds is one of that type, which the host described as a
        // protocol: a `Job<Int>` is a `Job`.
        if let (a, _) = actual.genericParts, let b = expected.plainName, a == b,
            isProtocolType(a)
        {
            return true
        }
        // Any sequence of the right elements, for a Swift `S: Sequence`.
        if let element = expected.sequenceElement {
            guard let actualElement = anySequenceElement(actual) else { return false }
            return fits(actualElement, element)
        }
        if case .tuple(let a) = actual, case .tuple(let b) = expected, !a.elements.isEmpty {
            return a.elements.count == b.elements.count
                && zip(a.elements, b.elements)
                    .allSatisfy { x, y in
                        (x.label == nil || y.label == nil || x.label == y.label)
                            && fits(x.type, y.type)
                    }
        }
        if case .parameter = actual { return true }
        if case .parameter = expected { return true }
        if let (ar, av) = actual.keyPathTypes, let (br, bv) = expected.keyPathTypes {
            return fits(br, ar) && fits(av, bv)
        }
        if let (root, value) = actual.keyPathTypes, case .function(let function) = expected {
            return function.parameters.count == 1 && fits(function.parameters[0].type, root)
                && fits(value, function.returns)
        }
        if case .function = actual, expected == .callable { return true }
        if actual == .callable, case .function = expected { return true }
        if actual.keyPathTypes != nil, expected == .callable { return true }
        if case .function(let a) = actual, case .function(let b) = expected {
            // A function that throws can't be passed where one that doesn't is
            // wanted, nor an `async` one where a sync one is.
            return a.parameters.count == b.parameters.count
                && zip(b.parameters, a.parameters).allSatisfy { fits($0.type, $1.type) }
                && (b.returns.isVoid || fits(a.returns, b.returns))
                && (!a.isThrowing || b.isThrowing) && (!a.isAsync || b.isAsync)
        }
        // A Swift generic type with its arguments is the type named without them (`Set<Int>` where
        // a `Set` is written).
        if let (a, _) = actual.genericParts, let b = expected.plainName, a == b,
            interpreter.bridged[a] != nil
        {
            return true
        }
        if let a = actual.plainName, let (b, _) = expected.genericParts, a == b,
            interpreter.bridged[a] != nil
        {
            return true
        }
        // A class is its superclass too.
        if let a = actual.plainName, let b = expected.plainName, isSubclass(a, of: b) {
            return true
        }
        // A struct's value is a record, as builtins that take any record see it.
        if expected == .record {
            if let name = actual.plainName, structInfo(named: name) != nil { return true }
            if case .tuple(let tuple) = actual, !tuple.elements.isEmpty { return true }
        }
        return false
    }
}

extension TypeChecker {
    // MARK: Protocols

    /// Whether `type` conforms to `proto`: as in Swift for the builtin types;
    /// a struct or enum by declaring it (an enum without associated values
    /// is Equatable and Hashable anyway, as in Swift).
    /// Whether `type` is what a type parameter's constraint asks for.
    func satisfies(_ type: TypeExpression, _ constraint: Swiit.Symbol.Constraint) -> Bool {
        switch constraint {
        case .conforms(let proto): conforms(type, to: proto.description)
        case .equals(let exact): type == .unknown || type.description == exact.description
        }
    }

    func conforms(_ type: TypeExpression, to proto: String) -> Bool {
        // `=String`: a bridged member for one element type only
        // (`joined(separator:)` where Element == String).
        if TypeChecker.looseProtocols.contains(proto) { return true }
        if proto.contains(" & ") {
            return proto.components(separatedBy: " & ").allSatisfy { conforms(type, to: $0) }
        }
        if proto.hasPrefix("=") {
            return type == .unknown || type.description == String(proto.dropFirst())
        }
        // A Swift type conforms as it declares: Int, [T] where T does,
        // ClosedRange<Int>.
        if let (bridgedType, bindings) = bridged(type) {
            if bridgedConforms(bridgedType, bindings, to: proto) { return true }
            // Or an extension says so: `extension Int: Fooable {}`.
            if let declared = describe(type)?.conformances {
                return declared.flatMap(protocolClosure).contains(proto)
            }
            return false
        }
        if proto == "CustomStringConvertible" { return true }
        // Swiit's own kinds, which aren't Swift types yet (foundations
        // step 4 makes them so, and these rules go).
        if type == .unknown || type == .record { return true }
        if case .parameter = type { return true }
        if type.keyPathTypes != nil { return proto == "Equatable" || proto == "Hashable" }
        if case .metatype = type { return proto == "Equatable" || proto == "Hashable" }
        // Tuples compare with `==`, but aren't Hashable or Encodable, as in Swift.
        if case .tuple(let tuple) = type, !tuple.elements.isEmpty {
            return proto == "Equatable"
                && tuple.elements.allSatisfy { conforms($0.type, to: proto) }
        }
        guard let name = type.plainName else { return false }
        if name == "Error" && proto == "Error" { return true }
        // A class is its superclass too (`T: Base`).
        if isSubclass(name, of: proto) { return true }
        // A struct or enum conforms by declaring it; Hashable is Equatable too.
        // A protocol is its own and what it takes in.
        if protocolInfo(named: name) != nil, protocolClosure(name).contains(proto) {
            return true
        }
        let description = describe(named: name)
        let declared = (description?.conformances ?? []).flatMap(protocolClosure)
        let withoutPayloads =
            description?.kind == .enumeration
            && description?.cases.allSatisfy { $0.payload.isEmpty } == true
        if declared.contains(proto) || proto == "Equatable" && declared.contains("Hashable") {
            // Swift only makes a Comparable enum's `<` without associated values.
            return proto == "Comparable" && description?.kind == .enumeration
                ? withoutPayloads : true
        }
        // Without associated values, an enum is Equatable and Hashable already.
        return withoutPayloads && (proto == "Equatable" || proto == "Hashable")
    }
}

extension TypeChecker {
    // MARK: Generics

    /// `type` with its type parameters replaced by what they're bound to;
    /// one not bound yet isn't known.
    func substitute(_ type: TypeExpression, _ bindings: [String: TypeExpression]) -> TypeExpression
    {
        if case .parameter(let parameter) = type { return bindings[parameter.name] ?? .unknown }
        return type.mapping { substitute($0, bindings) }
    }

    /// Binds the type parameters in `pattern` by matching it with `actual`,
    /// the type an argument turned out to have.
    func unify(
        _ pattern: TypeExpression,
        _ actual: TypeExpression,
        _ bindings: inout [String: TypeExpression]
    ) {
        if actual == .unknown { return }
        if case .parameter(let parameter) = pattern {
            let name = parameter.name
            if bindings[name] == nil || bindings[name] == .unknown { bindings[name] = actual }
            return
        }
        if let p = pattern.arrayElement {
            if let a = actual.arrayElement { unify(p, a, &bindings) }
        } else if let p = pattern.optionalWrapped {
            unify(p, actual.optionalWrapped ?? actual, &bindings)
        } else if case .metatype(let p) = pattern {
            if case .metatype(let a) = actual { unify(p.instance, a.instance, &bindings) }
        } else if let (pk, pv) = pattern.dictionaryTypes {
            if let (ak, av) = actual.dictionaryTypes {
                unify(pk, ak, &bindings)
                unify(pv, av, &bindings)
            }
        } else if let (p, ps) = pattern.genericParts {
            if let (a, as_) = actual.genericParts, p == a, ps.count == as_.count {
                for (p, a) in zip(ps, as_) { unify(p, a, &bindings) }
            }
        } else if case .tuple(let ps) = pattern {
            if case .tuple(let as_) = actual, ps.elements.count == as_.elements.count {
                for (p, a) in zip(ps.elements, as_.elements) { unify(p.type, a.type, &bindings) }
            }
        } else if let p = pattern.sequenceElement {
            if let element = anySequenceElement(actual) { unify(p, element, &bindings) }
        } else if let (pr, pv) = pattern.keyPathTypes {
            if let (ar, av) = actual.keyPathTypes {
                unify(pr, ar, &bindings)
                unify(pv, av, &bindings)
            } else if case .function(let function) = actual, function.parameters.count == 1 {
                unify(pr, function.parameters[0].type, &bindings)
                unify(pv, function.returns, &bindings)
            }
        } else if case .function(let p) = pattern {
            if case .function(let a) = actual, p.parameters.count == a.parameters.count {
                for (p, a) in zip(p.parameters, a.parameters) { unify(p.type, a.type, &bindings) }
                unify(p.returns, a.returns, &bindings)
            }
        }
    }

    /// The type of each item when iterating `type`.
    /// What a declared type gives a `for` loop, as Swift's protocols say: its `makeIterator()`'s
    /// `next()` (or `makeAsyncIterator()`'s, for `for await`) returns an optional element. Also
    /// whether that `next()` throws; nil if the type has no such iterator.
    func iteratedElement(
        of type: TypeExpression,
        async: Bool
    ) -> (element: TypeExpression, throws: Bool)? {
        guard type.isNominal, !type.isPrimitive, type.arrayElement == nil,
            type.dictionaryTypes == nil
        else { return nil }
        guard
            case .function(let makeIterator)? = try? memberType(
                of: type,
                async ? "makeAsyncIterator" : "makeIterator"
            ),
            case .function(let next)? = try? memberType(of: makeIterator.returns, "next"),
            let element = next.returns.optionalWrapped
        else {
            return nil
        }
        return (element, next.isThrowing)
    }

    func elementType(of type: TypeExpression, async: Bool = false) throws -> TypeExpression {
        if let name = type.plainName,
            let element = interpreter.bridged[name]?.checkedAssociatedTypes["Element"]
        {
            return element
        }
        if let (element, _) = iteratedElement(of: type, async: async) { return element }
        if type.genericParts != nil {
            // What `for await` reads: an AsyncSequence of the bridged types (a task group).
            if let (bridgedType, bindings) = bridged(type),
                bridgedType.conformance(named: "AsyncSequence") != nil,
                let element = bridgedType.checkedAssociatedTypes["Element"]
            {
                return substitute(element, bindings)
            }
            guard let element = bridgedElement(type) else {
                throw TypeError("can't iterate over \(type): it isn't a Sequence")
            }
            return element
        }
        if let element = type.arrayElement { return element }
        if type == .string { return .named("Character") }
        if let (key, value) = type.dictionaryTypes {
            return .tuple([.init(label: "key", type: key), .init(label: "value", type: value)])
        }
        if type == .unknown || type == .any { return .unknown }
        throw TypeError("can't iterate over \(type)")
    }
}
