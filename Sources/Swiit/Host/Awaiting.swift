import SwishKit

/// What `await` waits for, which a host registers: the type of the operand
/// (a handle the host made), the type it gives, and how to wait. Without one,
/// `await` is refused. (A handle protocol is the real exit; docs/Design/async.md.)
@_spi(Shell) public struct Awaiting {
    @_spi(Shell) public var operand: TypeAnnotation
    @_spi(Shell) public var result: TypeAnnotation
    /// Waits for the handle, or with no operand for the latest one; `throwing`
    /// for `try await`.
    var perform: (_ handle: Value?, _ throwing: Bool) throws -> Value
    /// Whether a value is one of its handles; `await` of anything else is an
    /// `async` call's, and gives the value.
    @_spi(Shell) public var isHandle: (Value) -> Bool
    /// What awaiting a handle of this type gives, where it depends on what
    /// the handle holds (the shell's `Job<Int>` gives an Int); `result` else.
    @_spi(Shell) public var resultOf: (TypeAnnotation) -> TypeAnnotation?

    @_spi(Shell) public init(operand: TypeAnnotation, result: TypeAnnotation, isHandle: @escaping (Value) -> Bool = { _ in true },
                             resultOf: @escaping (TypeAnnotation) -> TypeAnnotation? = { _ in nil },
                             perform: @escaping (Value?, Bool) throws -> Value) {
        self.operand = operand
        self.result = result
        self.isHandle = isHandle
        self.resultOf = resultOf
        self.perform = perform
    }
}

extension Interpreter {
    /// Binds `name` in the outermost scope to a value worked out each time it
    /// is read, and tells the checker its type.
    @_spi(Shell) public func bind(computed name: String, type: TypeAnnotation, _ value: @escaping () -> Value) {
        scopes[0].bindings[name] = Binding(computed: value)
        staticTypes[name] = type
    }
}
