import Foundation

/// A parameter's type, when the VM can check an argument against it without `conform`.
enum ParameterKind: UInt8 {
    case any, int, double, bool, string, typeParameter, other

    init(_ type: TypeExpression) {
        switch type {
        case .any: self = .any
        case .int: self = .int
        case .double: self = .double
        case .bool: self = .bool
        case .string: self = .string
        case .parameter: self = .typeParameter
        default: self = .other
        }
    }

    /// Whether `value` is plainly of this kind: `typeParameter` and `other` are never, and are
    /// conformed (a type parameter that no call has bound accepts anything: see
    /// `Interpreter.hasBoundTypeArguments`).
    func accepts(_ value: Value) -> Bool {
        switch (self, value.storage) {
        case (.any, _), (.int, .int), (.double, .double), (.bool, .bool), (.string, .string):
            true
        default: false
        }
    }

    /// `accepts` for the value in a register, which is not copied to be looked at.
    @inline(__always)
    func accepts(at register: UnsafeMutablePointer<Value>) -> Bool {
        switch self {
        case .any: true
        case .int: if case .int = register.pointee.storage { true } else { false }
        case .double: if case .double = register.pointee.storage { true } else { false }
        case .bool: if case .bool = register.pointee.storage { true } else { false }
        case .string: if case .string = register.pointee.storage { true } else { false }
        case .typeParameter, .other: false
        }
    }
}
