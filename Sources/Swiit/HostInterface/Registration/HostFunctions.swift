import Foundation
import Synchronization

// MARK: What a host exports

extension Symbol.Parameter {
    /// As the language's own builtins describe one.
    init(
        label: String?,
        name: String,
        type: ScriptType,
        variadic: Bool = false,
        documentation: String? = nil,
        defaultValue: Value? = nil,
        showsByType: Bool = false
    ) {
        self.init(
            label: label,
            name: name,
            type: type,
            arity: variadic ? .variadic : defaultValue.map { .defaulted(.value($0)) } ?? .required,
            documentation: documentation
        )
        self.showsByType = showsByType
    }
}

extension Symbol.Parameter {
    /// A parameter of a Swift type: `Symbol.Parameter(name: "count", type: Int.self)`.
    public init<T: BridgedType>(
        label: String? = nil,
        name: String,
        type: T.Type,
        arity: Arity = .required
    ) {
        self.init(label: label, name: name, type: ScriptType(type), arity: arity)
    }
}

// safe: its state is touched only holding the interpreter lock
/// A host's function or method as a value, as `repo.log` gives it. The
/// host calls it like any other function.
final class NativeFunction: Callable, @unchecked Sendable {
    let function: HostSymbol

    init(_ function: HostSymbol) {
        self.function = function
    }

    var description: String {
        "(Function)"
    }
}

// MARK: Converting values

extension Value {
    /// A function's result, whatever Swift type it has: a convertible
    /// value, an exported object, `Encodable` data as records, or nothing.
    init(returning result: Any) throws {
        switch result {
        case is Void: self = .nothing
        case let value as any BridgedType: self = value.value
        case let data as any Encodable: self = try ValueEncoder().encode(data)
        default: throw SwiitError("can't return a \(type(of: result)) to Swiit; make it Encodable")
        }
    }
}

/// What the host checks a parameter's arguments against.
func swiitParameterType<T: BridgedType>(_ type: T.Type) -> ScriptType { T.scriptType }
func swiitParameterEnums<T: BridgedType>(_ type: T.Type) -> [Value.EnumCase.Enumeration] {
    T.swiitEnums
}

/// What a function returns, for signatures and help.
func swiitReturnType(_ type: Any.Type) -> ScriptType {
    (type as? any BridgedType.Type)?.scriptType ?? .any
}

/// An argument the macro-generated code converts: a clear message naming
/// the function and parameter when it doesn't fit.
func swiitArgument<T: BridgedType>(
    _ arguments: Arguments,
    _ name: String,
    of function: String,
    as type: T.Type = T.self
) throws -> T {
    do {
        return try T(arguments[name] ?? .nothing)
    } catch let error as SwiitError {
        throw SwiitError("\(function): \(name): \(error)")
    }
}
