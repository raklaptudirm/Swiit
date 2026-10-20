import Foundation

extension Interpreter {
    // MARK: Declaring

    /// `enum Name: Raw { … }`: builds the type, checking raw values, and binds
    /// its name.
    func declare(_ decl: EnumDecl) throws {
        var cases: [EnumType.Case] = []
        var payloadTypes: [String: [TypeAnnotation]] = [:]
        var nextInt = 0
        var rawSeen: Set<Value> = []
        for enumCase in decl.cases {
            var raw: Value?
            if let rawType = decl.rawType {
                guard enumCase.associated.isEmpty else {
                    throw RuntimeError("\(decl.name).\(enumCase.name): an enum with raw values can't have associated values")
                }
                if let expr = enumCase.rawValue {
                    let value = try evaluate(expr)
                    guard let conforming = value.conforming(to: rawType) else {
                        throw RuntimeError("\(decl.name).\(enumCase.name)'s raw value must be \(rawType), not \(value.typeName)")
                    }
                    raw = conforming
                } else {
                    switch rawType {
                    case .int: raw = .int(nextInt)
                    case .string: raw = .string(enumCase.name)
                    default: throw RuntimeError("\(decl.name).\(enumCase.name) needs a raw value")
                    }
                }
                if case .int(let n) = raw { nextInt = n + 1 }
                guard rawSeen.insert(raw!).inserted else {
                    throw RuntimeError("\(decl.name).\(enumCase.name): raw value \(raw!) is used twice")
                }
            } else if enumCase.rawValue != nil {
                throw RuntimeError("\(decl.name).\(enumCase.name): only an enum with a raw type, like `enum \(decl.name): Int`, has raw values")
            }
            cases.append(EnumType.Case(name: enumCase.name, rawValue: raw, labels: enumCase.associated.map(\.label)))
            payloadTypes[enumCase.name] = enumCase.associated.map(\.type)
        }
        let type = EnumType(name: decl.name, cases: cases)
        enumPayloadTypes[ObjectIdentifier(type)] = payloadTypes
        enumConformances[ObjectIdentifier(type)] = decl.conformances
        enumTypeParameters[ObjectIdentifier(type)] = decl.typeParameters
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)
        try declareMembers(of: decl, on: type)
    }

    /// An enum's computed properties and methods, and its static ones.
    private func declareMembers(of decl: EnumDecl, on type: EnumType) throws {
        guard !decl.properties.isEmpty || !decl.methods.isEmpty || !decl.staticProperties.isEmpty || !decl.staticMethods.isEmpty
            || !decl.initializers.isEmpty else { return }
        let members = TypeMembers()
        try fill(members, of: decl.name, properties: decl.properties, methods: decl.methods, staticProperties: decl.staticProperties,
                 staticMethods: decl.staticMethods, initializers: decl.initializers, subscripts: [])
        enumMembers[ObjectIdentifier(type)] = members
    }

    /// `Direction(code: "N")`: through an `init` the enum declares, which sets `self` to a case.
    func constructEnum(_ type: EnumType, _ initializers: OverloadSet, _ arguments: [Argument], overload: Int?) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (initializer, bindings) = try resolve(narrowed(initializers, overload)) { try self.bind(values, to: $0) }
        let receiver = Receiver(.nothing, mutable: true, initializing: true)
        task.failedInit = false
        _ = try invoke(initializer, with: bindings, receiver: receiver)
        if task.failedInit {
            task.failedInit = false
            return .nothing
        }
        guard case .enumValue = receiver.value else { throw RuntimeError("\(type.name).init must set self to a case") }
        return receiver.value
    }

    /// A computed property of an enum's case, or a method as a function value; nil if there isn't one.
    func enumMember(_ name: String, of value: EnumValue) throws -> Value? {
        guard let members = enumMembers[ObjectIdentifier(value.type)] else { return nil }
        if let getter = members.computed[name] {
            return try invoke(getter, with: [:], receiver: Receiver(.enumValue(value), mutable: false))
        }
        guard let methods = members.methods[name] else { return nil }
        let bound = methods.candidates.map { method in
            Function(name: method.name, parameters: method.parameters, returnType: method.returnType,
                     body: .native { interpreter, arguments in
                         guard !method.isMutating else {
                             throw RuntimeError("mutating method '\(name)' must be called on a variable, as in value.\(name)(…)")
                         }
                         return try interpreter.invoke(method, with: arguments, receiver: Receiver(.enumValue(value), mutable: false))
                     }, documentation: method.documentation, isMutating: method.isMutating)
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// `Level.default`, `Level.make`: an enum's static member; nil if it has none by that name.
    func enumStaticMember(_ name: String, of type: EnumType) throws -> Value? {
        guard let members = enumMembers[ObjectIdentifier(type)] else { return nil }
        if let getter = members.staticComputed[name] { return try invoke(getter, with: [:]) }
        if let slot = members.statics[name] { return slot.value }
        return members.staticMethods[name].map(Value.function)
    }

    /// The enum a type annotation names, looking through optionals.
    func enumType(for type: TypeAnnotation?) -> EnumType? {
        switch type {
        case .named(let name)?: enumType(named: name)
        case .generic(let name, _)?: enumType(named: name)
        case .optional(let wrapped)?: enumType(for: wrapped)
        default: nil
        }
    }

    func enumType(named name: String) -> EnumType? {
        guard case .object(let type as EnumType)? = lookup(name)?.value else { return nil }
        return type
    }

    // MARK: Making cases

    /// `Kind.file`, `.failed(code: 2)` or `Kind.failed(code: 2)` for `type`:
    /// checks the case exists and its associated values' labels and types.
    func makeCase(_ type: EnumType, _ name: String, _ arguments: [Argument]?) throws -> Value {
        guard let definition = type.case(named: name) else {
            throw RuntimeError("\(type.name) has no case '\(name)'")
        }
        let written = "\(type.name).\(name)"
        guard let arguments else {
            guard definition.labels.isEmpty else {
                let labels = definition.labels.map { ($0 ?? "_") + ":" }.joined()
                throw RuntimeError("\(written) needs its associated values: \(written)(\(labels))")
            }
            return .enumValue(EnumValue(type: type, name: name))
        }
        guard !definition.labels.isEmpty else { throw RuntimeError("\(written) has no associated values") }
        guard arguments.count == definition.labels.count else {
            throw RuntimeError("\(written) has \(definition.labels.count) associated values, not \(arguments.count)")
        }
        let types = enumPayloadTypes[ObjectIdentifier(type)]?[name] ?? []
        var values: [Value] = []
        for (index, argument) in arguments.enumerated() {
            guard argument.label == definition.labels[index] else {
                let expected = definition.labels[index].map { "'\($0):'" } ?? "no label"
                throw RuntimeError("\(written): value #\(index + 1) needs \(expected)")
            }
            let type = index < types.count ? types[index] : .any
            let value = try evaluate(argument.value, expecting: type)
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError("\(written): value #\(index + 1) must be \(type), not \(value.typeName)")
            }
            values.append(conforming)
        }
        return .enumValue(EnumValue(type: type, name: name, values: values))
    }

    /// An expression whose type is known from context: a `.case` literal
    /// becomes a case of the expected enum.
    func evaluate(_ expr: Expr, expecting type: TypeAnnotation?) throws -> Value {
        if case .caseLiteral(let name, let arguments) = expr, let enumType = enumType(for: type) {
            return try makeCase(enumType, name, arguments)
        }
        return try evaluate(expr)
    }

    /// `value` as `type`, knowing the enums in scope; nil if it doesn't fit.
    func conform(_ value: Value, to type: TypeAnnotation) -> Value? {
        // A value already of a plain type, which is nearly every argument and result.
        switch (type, value) {
        case (.int, .int), (.double, .double), (.string, .string), (.bool, .bool), (.any, _): return value
        default: break
        }
        switch type {
        case .named, .generic, .someSequence:
            return conformNamed(value, to: type)
        default:
            return conformStructured(value, to: type)
        }
    }

    /// A value of a named type: a class, a protocol, a struct, an enum, a Swift value.
    private func conformNamed(_ value: Value, to type: TypeAnnotation) -> Value? {
        switch type {
        case .named(let name) where name.contains(" & "):
            // `A & B`: a value that is each.
            var held = value
            for part in name.components(separatedBy: " & ") {
                guard let conforming = conform(held, to: .named(part)) else { return nil }
                held = conforming
            }
            return held
        case .named(let name):
            // A class of the program's: an instance of it or of a subclass.
            if let type = classType(named: name) {
                guard case .object(let instance as ClassInstance) = value, instance.type.isSubclass(of: type) else { return nil }
                return value
            }
            // A protocol of the program's: any value whose type conforms.
            if protocolType(named: name) != nil { return self.value(value, conformsTo: name) ? value : nil }
            // A plain dynamic type (parsed JSON) is whatever it parsed as.
            if dynamicTypes[name]?.plain?.standsForAnything == true { return value }
            // A Swift value, boxed, is of its Swift type.
            if case .object(let box as SwiftValue) = value, box.typeName == name { return value }
            // A host's object is of the type it registered.
            if case .object(let object) = value, isHostObject(object), object.typeName == name, Bridge.types[name] != nil { return value }
            // A Character is held as the one-letter String it is.
            if name == "Character", case .string(let text) = value, text.count == 1 { return value }
            if case .record(let record) = value, record.typeName == name, structType(named: name) != nil {
                return value
            }
            // An Error is any value whose type conforms to it.
            if name == "Error", isError(value) { return value }
            guard case .enumValue(let enumValue) = value, let expected = enumType(named: name),
                  enumValue.type === expected else { return nil }
            return value
        case .generic(let name, _):
            // A Swift value, boxed, is of its Swift type.
            if case .object(let box as SwiftValue) = value, box.typeName == name { return value }
            // A generic enum of the program's: its arguments say what its cases hold, and it is its name.
            if enumType(named: name) != nil { return conform(value, to: .named(name)) }
            return nil
        case .someSequence:
            // Any sequence; the glue takes its items.
            return value
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// A value of a type made of others: a collection, a tuple, an optional, a type parameter.
    private func conformStructured(_ value: Value, to type: TypeAnnotation) -> Value? {
        switch type {
        case .metatype(let wrapped):
            // A type, of the kind the type parameter or class says (a subclass's type is its superclass's too).
            guard let held = annotation(ofTypeValue: value) else { return nil }
            switch wrapped {
            case .any, .parameter, .unknown: return value
            case .named(let name):
                if case .object(let object as ClassType) = value, let above = classType(named: name) { return object.isSubclass(of: above) ? value : nil }
                if protocolType(named: name) != nil || name == "Error" { return typeValue(value, conformsTo: name) ? value : nil }
                return held == wrapped ? value : nil
            default: return held == wrapped ? value : nil
            }
        case .parameter(let name):
            // A type parameter is what the call bound it to, if the body names it; otherwise any type.
            guard let bound = lookup(Interpreter.typeArgumentPrefix + name)?.value, let annotation = annotation(ofTypeValue: bound) else { return value }
            return conform(value, to: annotation)
        case .optional(let wrapped):
            return value == .nothing ? value : conform(value, to: wrapped)
        case .list(let element):
            guard case .list(let items) = value else { return value.conforming(to: type) }
            var converted: [Value] = []
            for item in items {
                guard let conforming = conform(item, to: element) else { return nil }
                converted.append(conforming)
            }
            return .list(converted)
        case .dictionary(let keyType, let valueType):
            guard case .dictionary(let dictionary) = value else { return value.conforming(to: type) }
            var made = ValueDictionary()
            for (key, entry) in dictionary {
                guard let conformingKey = conform(key, to: keyType), let conformingValue = conform(entry, to: valueType) else { return nil }
                made[conformingKey] = conformingValue
            }
            return .dictionary(made)
        case .tuple(let elements):
            // Each element as its own type, which may be a protocol of the program's.
            guard case .record(let record) = value, record.typeName == nil, record.count == elements.count else {
                return value.conforming(to: type)
            }
            var made = Record()
            for (element, field) in zip(elements, record) {
                guard let conforming = conform(field.value, to: element.type) else { return nil }
                made[element.label ?? field.key] = conforming
            }
            return .record(made)
        default:
            return value.conforming(to: type)
        }
    }

    /// A case from the command line: its name (`directory` or `.directory`),
    /// or its raw value.
    func enumCase(fromText text: String, _ type: EnumType) -> Value? {
        let name = text.hasPrefix(".") ? String(text.dropFirst()) : text
        if let definition = type.case(named: name), definition.labels.isEmpty {
            return .enumValue(EnumValue(type: type, name: name))
        }
        return type.cases.first { $0.labels.isEmpty && $0.rawValue?.description == text }
            .map { .enumValue(EnumValue(type: type, name: $0.name)) }
    }

    // MARK: Matching

    /// Whether `value` matches `pattern`, binding what the pattern names.
    func match(_ pattern: Pattern, _ value: Value, into bindings: inout [String: Binding]) throws -> Bool {
        switch pattern {
        case .wildcard:
            return true
        case .binding(let name, let mutable):
            bindings[name] = Binding(value: value, mutable: mutable)
            return true
        case .enumCase(let typeName, let name, let arguments):
            guard case .enumValue(let enumValue) = value else { return false }
            if let typeName {
                guard let named = enumType(named: typeName) else { throw RuntimeError("no enum named \(typeName)") }
                guard named === enumValue.type else { return false }
            }
            guard let definition = enumValue.type.case(named: name) else {
                throw RuntimeError("\(enumValue.type.name) has no case '\(name)'")
            }
            guard enumValue.name == name else { return false }
            guard let arguments else { return true } // `.failed` matches whatever it carries.
            guard arguments.count == enumValue.values.count else {
                throw RuntimeError("\(enumValue.type.name).\(name) has \(enumValue.values.count) associated values, not \(arguments.count)")
            }
            for (index, argument) in arguments.enumerated() {
                if let label = argument.label, label != definition.labels[index] {
                    throw RuntimeError("\(enumValue.type.name).\(name)'s value #\(index + 1) isn't labeled '\(label)'")
                }
                guard try match(argument.pattern, enumValue.values[index], into: &bindings) else { return false }
            }
            return true
        case .expression(let expr):
            // A range matches what's in it; anything else, what's equal to it.
            if case .binary(let op, let lower, let upper) = expr, op == .closedRange || op == .halfOpenRange {
                let low = try evaluate(lower)
                let high = try evaluate(upper)
                guard let number = value.asDouble, let from = low.asDouble, let to = high.asDouble else { return false }
                return number >= from && (op == .closedRange ? number <= to : number < to)
            }
            let expected = try evaluate(expr)
            if case .enumValue = value, case .string = expected {
                throw RuntimeError("can't compare \(value.typeName) with a String; match a case like .\(expected)")
            }
            if case .object = value, let text = value.text { return Value.string(text).isEqual(to: expected) }
            return value.isEqual(to: expected)
        case .cast(let inner, let type):
            guard let converted = conform(value, to: type) else { return false }
            return try match(inner, converted, into: &bindings)
        case .isType(let type):
            return conform(value, to: type) != nil
        case .some(let inner):
            return value != .nothing ? try match(inner, value, into: &bindings) : false
        case .partialRange(let lower, let upper, let closed):
            if let lower, try apply(.less, value, try evaluate(lower)) == .bool(true) { return false }
            if let upper {
                let bound = try evaluate(upper)
                return try apply(closed ? .lessEqual : .less, value, bound) == .bool(true)
            }
            return true
        case .tuple(let patterns):
            guard case .record(let record) = value, record.typeName == nil, record.count == patterns.count else { return false }
            for (pattern, field) in zip(patterns, record) {
                guard try match(pattern, field.value, into: &bindings) else { return false }
            }
            return true
        }
    }

    /// Whether a value is an Error: of a struct or enum declared `: Error`, or
    /// what the interpreter throws (`Error`, `CancellationError`).
    func isError(_ value: Value) -> Bool {
        switch value {
        case .record(let record):
            guard let name = record.typeName else { return false }
            return name == "Error" || structType(named: name)?.conformances.contains("Error") == true
        case .enumValue(let enumValue):
            return enumConformances[ObjectIdentifier(enumValue.type)]?.contains("Error") == true
        case .object(let instance as ClassInstance):
            return instance.type.allConformances.contains("Error")
        default:
            return false
        }
    }

    /// The first of `cases` whose pattern (and `where`) matches `subject`, and
    /// what it binds; one without patterns matches anything, binding
    /// `anyName` if given (a bare `catch` binds `error`).
    func firstMatch(_ cases: [SwitchCase], _ subject: Value, anyName: String? = nil) throws -> (index: Int, bindings: [String: Binding])? {
        for (index, switchCase) in cases.enumerated() {
            if switchCase.patterns.isEmpty {
                return (index, anyName.map { [$0: Binding(value: subject, mutable: false)] } ?? [:])
            }
            for (position, pattern) in switchCase.patterns.enumerated() {
                var bindings: [String: Binding] = [:]
                guard try match(pattern, subject, into: &bindings) else { continue }
                // The `where` is the last pattern's, as in Swift: in `case 1, 2
                // where c:`, a 1 matches whatever c is.
                if let guardExpr = switchCase.guardExpr, position == switchCase.patterns.count - 1 {
                    scopes.append(Scope(bindings))
                    defer { scopes.removeLast() }
                    let verdict = try evaluate(guardExpr)
                    guard case .bool(let pass) = verdict else {
                        throw RuntimeError("a case's where must be a Bool, not \(verdict.typeName)")
                    }
                    guard pass else { continue }
                }
                return (index, bindings)
            }
        }
        return nil
    }

    /// Runs a switch: the first case whose pattern (and `where`) matches,
    /// then on through `fallthrough`. No match is an error: Swift checks a
    /// switch covers everything when compiling; Swiit can only check here.
    func runSwitch(_ node: SwitchStatement) throws {
        let subject = try evaluate(node.subject)
        guard let start = try firstMatch(node.cases, subject) else {
            throw RuntimeError("switch over \(subject.description.isEmpty ? subject.typeName : subject.description) matched no case; add one, or a default")
        }

        var index = start.index
        var bindings = start.bindings
        while index < node.cases.count {
            do {
                try runBlock(node.cases[index].body, declaring: bindings)
                return
            } catch ControlFlow.fallthroughCase {
                index += 1
                bindings = [:]
            } catch ControlFlow.breakLoop(nil) {
                return // `break` leaves the switch.
            }
        }
    }
}

extension Interpreter {
    /// A case of an enum the prelude or the standard library module
    /// declares: `FileType.directory`.
    func declaredCase(_ type: String, _ name: String) -> Value {
        .enumValue(EnumValue(type: enumType(named: type)!, name: name))
    }
}
