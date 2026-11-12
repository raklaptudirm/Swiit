import Foundation
import Synchronization

/// A Swift enum without associated values is an enum scripts can use (as a parameter, `volume .high`
/// or `volume(.high)`, a result, and in `switch`) by saying it converts:
///
///     public enum Level: String, CaseIterable, BridgedType { case low, high }
///
/// The host learns it by name from the functions that take it.
extension BridgedType where Self: CaseIterable & Hashable & Sendable {
    public static var scriptType: ScriptType {
        .named(Value.EnumCase.Enumeration.of(Self.self).name)
    }

    public init(_ swiitValue: Value) throws {
        guard case .enumValue(let value) = swiitValue.storage,
            value.type === Value.EnumCase.Enumeration.of(Self.self),
            let found = Self.allCases.first(where: { String(describing: $0) == value.name })
        else {
            throw SwiitError.expected(Value.EnumCase.Enumeration.of(Self.self).name, swiitValue)
        }
        self = found
    }

    public var value: Value {
        .enumValue(
            Value.EnumCase(
                type: Value.EnumCase.Enumeration.of(Self.self),
                name: String(describing: self)
            )
        )
    }
}

extension Value.EnumCase.Enumeration {
    /// The enum a Swift enum is, with its cases and raw values as Swiit sees them; one instance
    /// per type, so values compare equal across calls.
    static func of<E: CaseIterable>(_ type: E.Type) -> Value.EnumCase.Enumeration {
        EnumRegistry.shared.type(for: type) {
            Value.EnumCase.Enumeration(
                name: String(describing: type),
                cases: type.allCases.map { value in
                    let raw = (value as? any RawRepresentable)?.rawValue
                    return Value.EnumCase.Enumeration.Case(
                        name: String(describing: value),
                        rawValue: raw.flatMap { raw in
                            switch raw {
                            case let int as Int: .int(int)
                            case let string as String: .string(string)
                            default: nil
                            }
                        }
                    )
                },
                conformances: type is any Comparable.Type ? ["Comparable"] : []
            )
        }
    }
}

/// Each Swift enum's `EnumType`, made once.
final class EnumRegistry: Sendable {
    static let shared = EnumRegistry()
    private let types = Mutex<[ObjectIdentifier: Value.EnumCase.Enumeration]>([:])

    func type(
        for key: Any.Type,
        _ make: () -> Value.EnumCase.Enumeration
    ) -> Value.EnumCase.Enumeration {
        types.withLock { types in
            if let type = types[ObjectIdentifier(key)] { return type }
            let type = make()
            types[ObjectIdentifier(key)] = type
            return type
        }
    }
}
