import Foundation

/// What Swift takes a string literal to be, by its text: a single Unicode scalar, a single
/// character, or a string. Each is made by its own initializer (`init(unicodeScalarLiteral:)`,
/// `init(extendedGraphemeClusterLiteral:)`, `init(stringLiteral:)`), which a type of Swift's that
/// can be written as a literal has.
enum TextLiteralKind: CaseIterable {
    case scalar, cluster, string

    /// The label of the initializer that takes this kind.
    var label: String {
        switch self {
        case .scalar: "unicodeScalarLiteral"
        case .cluster: "extendedGraphemeClusterLiteral"
        case .string: "stringLiteral"
        }
    }

    init?(label: String) {
        guard let found = Self.allCases.first(where: { $0.label == label }) else { return nil }
        self = found
    }

    /// The kinds a text is, the most specific first: a single scalar is also a character and a string.
    static func applicable(to text: String) -> [TextLiteralKind] {
        if text.unicodeScalars.count == 1 { return [.scalar, .cluster, .string] }
        if text.count == 1 { return [.cluster, .string] }
        return [.string]
    }

    /// The value an initializer for this kind takes for `text`, given the type of its parameter: a
    /// string, a `Character` or a `Unicode.Scalar`, which are the types Swift writes a literal as.
    func argument(_ text: String, for parameter: TypeAnnotation) -> Value? {
        switch parameter {
        case .string:
            return .string(text)
        case .named("Character"):
            return text.count == 1
                ? Value(boxing: Character(text), as: Symbol.ID(hostType: "Character")) : nil
        case .named("Unicode.Scalar"):
            return text.unicodeScalars.count == 1
                ? Value(
                    boxing: text.unicodeScalars.first!,
                    as: Symbol.ID(hostType: "Unicode.Scalar")
                )
                : nil
        default:
            return nil
        }
    }
}
