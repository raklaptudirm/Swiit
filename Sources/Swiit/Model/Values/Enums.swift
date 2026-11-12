extension Value.EnumCase {
    // safe: its state is touched only holding the interpreter lock
    /// An enum's definition: its name and cases, in order. Declared in Swiit
    /// (`enum FileType { case file, directory }`) or by the host.
    /// Types compare by identity, so two enums with the same name are distinct.
    final class Enumeration: LanguageObject, DeclaredType, @unchecked Sendable {
        struct Case: Sendable, Equatable {
            let name: String
            /// For an enum with raw values (`enum Level: Int`).
            let rawValue: Value?
            /// Labels of its associated values, nil for one without a label;
            /// empty for a case that has none.
            let labels: [String?]

            init(name: String, rawValue: Value? = nil, labels: [String?] = []) {
                self.name = name
                self.rawValue = rawValue
                self.labels = labels
            }
        }

        let name: String
        let cases: [Case]
        let id: Symbol.ID
        /// The protocols a host's enum conforms to in Swift, of those that change what a script may
        /// do with it beyond what every enum without payloads can: `Comparable`, whose `<` goes by
        /// the cases' order, as Swift's own does.
        let conformances: [String]

        /// An enum the host provides, named by the Swift type's name.
        init(name: String, cases: [Case], conformances: [String] = []) {
            self.name = name
            self.cases = cases
            self.id = .host(name)
            self.conformances = conformances
        }

        /// An enum a program declares, which is a type of its own.
        init(declaring name: String, cases: [Case]) {
            self.name = name
            self.cases = cases
            self.id = .declare(name)
            self.conformances = []
        }

        func `case`(named name: String) -> Case? {
            cases.first { $0.name == name }
        }

        /// The case with this raw value, as `Level(rawValue: 2)` gives it.
        func `case`(rawValue: Value) -> Value.EnumCase? {
            cases.first { $0.rawValue == rawValue && $0.labels.isEmpty }
                .map { Value.EnumCase(type: self, name: $0.name) }
        }

        /// Every case, if none has associated values (Swift's `CaseIterable`).
        var allCases: [Value.EnumCase]? {
            guard cases.allSatisfy(\.labels.isEmpty) else { return nil }
            return cases.map { Value.EnumCase(type: self, name: $0.name) }
        }

        // MARK: LanguageObject

        var typeName: String { "enum" }

        var memberNames: [String] {
            cases.map(\.name) + (allCases == nil ? [] : ["allCases"])
        }

        /// A case without associated values, or `allCases`. Cases with them are
        /// made by calling, which the interpreter handles.
        func member(_ name: String) -> Value? {
            if name == "allCases", let all = allCases { return .list(all.map(Value.enumValue)) }
            guard let found = `case`(named: name), found.labels.isEmpty else { return nil }
            return .enumValue(Value.EnumCase(type: self, name: name))
        }

        /// A type, not data: it shows as `enum Name`.

        var description: String { "enum \(name)" }
    }
}

extension Value {
    /// One value of an enum: a case, and its associated values if it has any.
    struct EnumCase: Sendable, Hashable, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        let type: Value.EnumCase.Enumeration
        let name: String
        /// The enum it is a case of.
        var typeName: String { type.name }
        /// The ID of the enum it is a case of.
        var id: Symbol.ID { type.id }
        /// In the order the case declares them.
        let values: [Value]

        /// What the case carries, in the order its declaration gives: each value under its label,
        /// or under its position (`"0"`, `"1"`) if it has none, as a tuple's elements are named.
        /// Empty for a case with none.
        var payload: Value.Tuple {
            let labels = definition?.labels ?? []
            var tuple = Value.Tuple()
            for (index, value) in values.enumerated() {
                tuple[(index < labels.count ? labels[index] : nil) ?? String(index)] = value
            }
            return tuple
        }

        init(type: Value.EnumCase.Enumeration, name: String, values: [Value] = []) {
            self.type = type
            self.name = name
            self.values = values
        }

        var definition: Value.EnumCase.Enumeration.Case? {
            type.case(named: name)
        }

        /// What `customMirror` gives: nothing for a case that carries nothing; else one child
        /// labeled with the case's name, as Swift's mirror of an enum has it.
        var reflected: [Mirror.Child] {
            guard !values.isEmpty else { return [] }
            let labels = definition?.labels ?? []
            let carried: Value
            if values.count == 1, labels.first.flatMap({ $0 }) == nil {
                carried = values[0]
            } else {
                carried = .tuple(payload)
            }
            return [Mirror.Child(label: name, value: carried)]
        }

        /// The raw value its declaration gives it, if the enum has them (`enum Level: Int`).
        var rawValue: Value? {
            definition?.rawValue
        }

        /// Where it comes in the declaration, for sorting.
        var index: Int {
            type.cases.firstIndex { $0.name == name } ?? 0
        }

        static func == (lhs: EnumCase, rhs: EnumCase) -> Bool {
            lhs.type === rhs.type && lhs.name == rhs.name && lhs.values == rhs.values
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(type))
            hasher.combine(name)
            hasher.combine(values)
        }

        /// As Swift prints it: `directory`, or `failed(code: 2)`.
        var description: String {
            guard !values.isEmpty else { return name }
            let labels = definition?.labels ?? []
            let parts = values.enumerated()
                .map { index, value in
                    let label = index < labels.count ? labels[index] : nil
                    return (label.map { "\($0): " } ?? "") + value.description
                }
            return "\(name)(\(parts.joined(separator: ", ")))"
        }

        /// With its type, and its values as they'd be written:
        /// `Result.failed(code: 2, "no such file")`.
        var debugDescription: String {
            let written = "\(type.name).\(name)"
            guard !values.isEmpty else { return written }
            let labels = definition?.labels ?? []
            let parts = values.enumerated()
                .map { index, value in
                    let label = index < labels.count ? labels[index] : nil
                    return (label.map { "\($0): " } ?? "") + value.debugDescription
                }
            return "\(written)(\(parts.joined(separator: ", ")))"
        }
    }
}
