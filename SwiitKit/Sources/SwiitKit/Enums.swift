/// An enum's definition: its name and cases, in order. Declared in Swish
/// (`enum FileType { case file, directory }`) or by the shell and plugins.
/// Types compare by identity, so two enums with the same name are distinct.
public final class EnumType: SwiitObject, @unchecked Sendable {
    public struct Case: Sendable, Equatable {
        public let name: String
        /// For an enum with raw values (`enum Level: Int`).
        public let rawValue: Value?
        /// Labels of its associated values, nil for one without a label;
        /// empty for a case that has none.
        public let labels: [String?]

        public init(name: String, rawValue: Value? = nil, labels: [String?] = []) {
            self.name = name
            self.rawValue = rawValue
            self.labels = labels
        }
    }

    public let name: String
    public let cases: [Case]

    public init(name: String, cases: [Case]) {
        self.name = name
        self.cases = cases
    }

    public func `case`(named name: String) -> Case? {
        cases.first { $0.name == name }
    }

    /// The case with this raw value, as `Level(rawValue: 2)` gives it.
    public func `case`(rawValue: Value) -> EnumValue? {
        cases.first { $0.rawValue == rawValue && $0.labels.isEmpty }.map { EnumValue(type: self, name: $0.name) }
    }

    /// Every case, if none has associated values (Swift's `CaseIterable`).
    public var allCases: [EnumValue]? {
        guard cases.allSatisfy(\.labels.isEmpty) else { return nil }
        return cases.map { EnumValue(type: self, name: $0.name) }
    }

    // MARK: SwiitObject

    public var typeName: String { "enum" }

    public var memberNames: [String] {
        cases.map(\.name) + (allCases == nil ? [] : ["allCases"])
    }

    /// A case without associated values, or `allCases`. Cases with them are
    /// made by calling, which the interpreter handles.
    public func member(_ name: String) -> Value? {
        if name == "allCases", let all = allCases { return .list(all.map(Value.enumValue)) }
        guard let found = `case`(named: name), found.labels.isEmpty else { return nil }
        return .enumValue(EnumValue(type: self, name: name))
    }

    /// A type, not data: it shows as `enum Name`.
    public var fields: Record? { nil }

    public var description: String { "enum \(name)" }
}

/// One value of an enum: a case, and its associated values if it has any.
public struct EnumValue: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let type: EnumType
    public let name: String
    /// In the order the case declares them.
    public let values: [Value]

    public init(type: EnumType, name: String, values: [Value] = []) {
        self.type = type
        self.name = name
        self.values = values
    }

    public var definition: EnumType.Case? {
        type.case(named: name)
    }

    public var rawValue: Value? {
        definition?.rawValue
    }

    /// Where it comes in the declaration, for sorting.
    public var index: Int {
        type.cases.firstIndex { $0.name == name } ?? 0
    }

    public static func == (lhs: EnumValue, rhs: EnumValue) -> Bool {
        lhs.type === rhs.type && lhs.name == rhs.name && lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type))
        hasher.combine(name)
        hasher.combine(values)
    }

    /// As Swift prints it: `directory`, or `failed(code: 2)`.
    public var description: String {
        guard !values.isEmpty else { return name }
        let labels = definition?.labels ?? []
        let parts = values.enumerated().map { index, value in
            let label = index < labels.count ? labels[index] : nil
            return (label.map { "\($0): " } ?? "") + value.description
        }
        return "\(name)(\(parts.joined(separator: ", ")))"
    }

    /// With its type, and its values as they'd be written:
    /// `Result.failed(code: 2, "no such file")`.
    public var debugDescription: String {
        let written = "\(type.name).\(name)"
        guard !values.isEmpty else { return written }
        let labels = definition?.labels ?? []
        let parts = values.enumerated().map { index, value in
            let label = index < labels.count ? labels[index] : nil
            return (label.map { "\($0): " } ?? "") + value.debugDescription
        }
        return "\(written)(\(parts.joined(separator: ", ")))"
    }
}
