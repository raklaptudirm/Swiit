import Foundation
import SwiftSyntax

/// A slot of the running frame: a local of the function, or a temporary above them.
typealias Register = UInt16

/// One step of compiled code. Every payload is a small integer, so an instruction is copied without
/// reference counting; whatever has a reference (a literal, a name, a type, a statement) is in the
/// `Code`'s tables and named by an index. Three-address: an operation reads its operands from
/// registers and writes its destination.
///
/// A jump's offset is counted from the instruction after it.
enum Instruction {
    // MARK: Statements

    /// Counts a step (`checkInterrupt`, as each statement of the tree evaluator does) and makes the
    /// statement at `range` of `Code.ranges` the one an error is told it happened in.
    case step(range: Int32)
    /// Makes the statement the one an error is told it happened in, without a step: for what a
    /// statement does again after the statements inside it, such as a loop's condition.
    case at(range: Int32)
    /// One more step: each pass through a loop's body counts one before its statements do.
    case tick
    /// Tells the host a statement finished (`Interpreter.Host.didFinishStatement`), with the value it
    /// gave when it is an expression.
    case finished(statement: UInt32, value: Register)

    // MARK: Values

    case loadConstant(dst: Register, constant: UInt32)
    case move(dst: Register, src: Register)
    /// A name looked up in the scopes: a global, a function, a type.
    case loadVariable(dst: Register, name: UInt32)
    /// Sets `count` registers from `first` to nothing: the locals of a block that has ended.
    case clear(first: Register, count: Register)
    /// `dst` is `src` as the type says, or an error (`let x: Double = 1`).
    case conform(dst: Register, src: Register, type: UInt32)

    // MARK: Operators

    case binary(op: BinaryOperator, dst: Register, lhs: Register, rhs: Register)
    case unary(op: UnaryOperator, dst: Register, src: Register)
    /// `a && b` and `a || b`: the left operand must be a Bool, and when it settles the result the
    /// code jumps over the right one, leaving it in the register.
    case shortCircuit(op: BinaryOperator, register: Register, offset: Int32)
    /// The result of `a && b` or `a || b` must be a Bool.
    case needBool(op: BinaryOperator, register: Register)
    /// `a ?? b`: jumps over the right operand when the left is not nil.
    case jumpIfNotNil(register: Register, offset: Int32)

    /// `x = v`, `x += v`: the local takes the value, or the operator applied to its own.
    case assign(local: Register, op: BinaryOperator?, value: Register)

    // MARK: Control

    case jump(offset: Int32)
    /// A condition: jumps when it is false, and it must be a Bool.
    case jumpIfFalse(condition: Register, offset: Int32)
    case jumpIfTrue(condition: Register, offset: Int32)
    /// `for i in a..<b`: reads the Int bounds from `lower` and `upper` and leaves the range in the two
    /// registers from `counter` (the next value and the end).
    case rangeStart(op: BinaryOperator, counter: Register, lower: Register, upper: Register)
    /// The next value of a range into `variable`, or a jump out of the loop.
    case rangeNext(counter: Register, variable: Register, exit: Int32)

    // MARK: Calls

    /// Calls what `Code.callSites[site]` names with the arguments in the registers from `arguments`.
    /// A script function that compiled takes them where they are: they are its first registers.
    case call(dst: Register, site: UInt32, arguments: Register)
    case returnValue(Register)
    case returnNothing
}

/// A call as written: what it calls, and the labels of its arguments.
final class CallSite {
    let name: String
    /// The callee as the checker left it (`f`, or `f` with the overload chosen), which a call the VM
    /// does not make itself is evaluated with.
    let callee: Expr
    let labels: [String?]
    /// The function this site called last, and whether its labels and arity fit this site: a site
    /// calls the same function nearly every time.
    @exclusivity(unchecked) var lastFunction: Function?
    @exclusivity(unchecked) var lastFits = false

    init(name: String, callee: Expr, labels: [String?]) {
        self.name = name
        self.callee = callee
        self.labels = labels
    }
}

/// A parameter's type, when the VM can check an argument against it without `conform`.
enum ParameterKind: UInt8 {
    case any, int, double, bool, string, other

    init(_ type: TypeExpression) {
        switch type {
        case .any: self = .any
        case .int: self = .int
        case .double: self = .double
        case .bool: self = .bool
        case .string: self = .string
        default: self = .other
        }
    }

    /// Whether `value` is plainly of this kind: `other` is never, and is conformed.
    func accepts(_ value: Value) -> Bool {
        switch (self, value.storage) {
        case (.any, _), (.int, .int), (.double, .double), (.bool, .bool), (.string, .string):
            true
        default: false
        }
    }
}

/// What a function body compiled to.
final class Code {
    var instructions: [Instruction] = []
    var constants: [Value] = []
    var names: [String] = []
    var types: [TypeExpression] = []
    var statements: [Statement] = []
    var callSites: [CallSite] = []
    /// The source range of each statement a `step` or `at` names; nil where the program had none.
    var ranges: [SourceRange?] = []
    /// How many registers a run of it uses: the locals the frame resolver counted, then temporaries.
    var frameSize = 0
    var parameterCount = 0
    /// What each parameter asks of an argument, for the common types a call can check at a glance.
    var parameterKinds: [ParameterKind] = []
    /// The body is one expression that is the result (a closure's, or a short function's), which the
    /// tree evaluator runs without counting a statement: so does the VM.
    var isImplicitReturn = false
}
