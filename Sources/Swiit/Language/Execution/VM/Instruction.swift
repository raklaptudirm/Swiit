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
    /// An expression that names only globals and types, evaluated by the tree evaluator: `Oops.bad`.
    case evaluate(dst: Register, expression: UInt32)
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

    // MARK: Patterns

    /// Matches the value against the pattern `Code.patterns[pattern]`, as the tree evaluator does:
    /// the names it binds go to their registers, or the code jumps by `fail`.
    case match(pattern: UInt32, value: Register, fail: Int32)
    /// A `case`'s `where`: jumps when it is false, and it must be a Bool.
    case jumpIfWhereFalse(condition: Register, offset: Int32)
    /// A switch whose cases none matched.
    case noMatch(value: Register)
    case jumpIfNil(register: Register, offset: Int32)

    // MARK: Errors

    /// `throw value`.
    case throwValue(Register)
    /// An error `Code.handlers` caught is dealt with: kept by the clause that took it, thrown again
    /// when none did, thrown as a fatal one for `try!`, or told to the host for a `defer` that failed.
    case caughtTaken
    case rethrow
    case fatalize
    case reportDeferred
    /// `guard`'s `else` did not leave.
    case guardCarriedOn

    // MARK: Deferred blocks

    /// A block with `defer`s keeps in a register which of them it has reached: this one is.
    case deferMark(register: Register, bit: UInt8)
    /// Jumps over a `defer` the block has not reached.
    case jumpIfNotDeferred(register: Register, bit: UInt8, offset: Int32)
    /// Deferred blocks run without telling the host's observer each statement; these bracket them.
    case quietBegin
    case quietEnd

    // MARK: Captured variables

    /// The local in this register is captured by a closure: from here on it is a cell the closure
    /// shares, and the register holds the cell.
    case box(register: Register)
    case loadCell(dst: Register, box: Register)
    /// A `weak` or `unowned` variable is read as what it refers to, or nil once that is gone.
    case derefWeak(register: Register)
    case storeCell(box: Register, src: Register)
    case assignCell(box: Register, op: BinaryOperator, value: Register)
    /// The closure `Code.closures[site]` made of the cells and values it captures.
    case makeClosure(dst: Register, site: UInt32)
    /// Assigns a variable that is not a local, by name: a global, or one a closure captured.
    case assignByName(site: UInt32, value: Register)

    // MARK: What the tree evaluator runs

    /// An expression the compiler does not compile, evaluated by the tree evaluator over a frame of
    /// the locals it mentions.
    case evaluateTree(dst: Register, node: UInt32)
    /// A statement it does not compile (an assignment through a path), run the same way.
    case runTree(node: UInt32)

    // MARK: Iteration

    /// `for x in s`: the iterator over a collection, a string, a dictionary or whatever `makeIterator`
    /// gives.
    case iterate(dst: Register, sequence: Register)
    /// The next element into `variable`, or a jump out of the loop.
    case iterateNext(iterator: Register, variable: Register, exit: Int32)
    /// An element that did not fit the pattern of a `for`.
    case iterationMismatch(element: Register)

    // MARK: Calls

    /// Calls what `Code.callSites[site]` names with the arguments in the registers from `arguments`.
    /// A script function that compiled takes them where they are: they are its first registers.
    case call(dst: Register, site: UInt32, arguments: Register)
    /// Calls the function in a register (a closure, or a parameter of function type).
    case callValue(dst: Register, callee: Register, site: UInt32, arguments: Register)
    /// What the `inout` parameters hold as the function ends, for the call to hand back.
    case inoutOutputs(first: Register, count: UInt16)
    /// The register is what the call left in its `index`th `inout` parameter.
    case takeInout(dst: Register, index: UInt16)
    case finishInout
    case returnValue(Register)
    case returnNothing
}

/// A local a piece of code the tree evaluator runs mentions, which it is given in its frame.
struct TreeLocal {
    let slot: Register
    let name: String
    let mutable: Bool
    /// Kept in a cell a closure shares: the frame shares the cell too.
    let boxed: Bool
}

/// An expression or a statement the compiler leaves to the tree evaluator, with the locals it
/// mentions.
final class TreeNode {
    enum Source {
        case expression(Expr)
        case statement(Statement)
    }

    let source: Source
    let locals: [TreeLocal]
    /// How many slots the frame has: as many as the function's locals.
    let frameSize: Int

    init(source: Source, locals: [TreeLocal], frameSize: Int) {
        self.source = source
        self.locals = locals
        self.frameSize = frameSize
    }
}

/// A local a closure names, kept in a cell the closure shares.
struct CapturedCell {
    let name: String
    let register: Register
    let mutable: Bool
}

/// A value a capture list takes when the closure is made: `[weak self, count]`.
struct TakenValue {
    let name: String
    let register: Register
    let isWeak: Bool
    let isUnowned: Bool
}

/// A closure as written: what it captures from the code that makes it.
final class ClosureSite {
    let literal: ClosureLiteral
    /// The locals it names, each kept in a cell the closure shares.
    let cells: [CapturedCell]
    /// The other names it uses, which are the enclosing closure's own captures, if anything.
    let others: [String]
    let captures: [TakenValue]

    init(
        literal: ClosureLiteral,
        cells: [CapturedCell],
        others: [String],
        captures: [TakenValue]
    ) {
        self.literal = literal
        self.cells = cells
        self.others = others
        self.captures = captures
    }
}

/// A call as written: what it calls, and the labels of its arguments.
final class CallSite {
    /// The global name it calls, when it calls one: only such a call can be made by the VM itself.
    let name: String?
    /// The callee as the checker left it (`f`, or `f` with the overload chosen), which a call the VM
    /// does not make itself is evaluated with.
    let callee: Expr
    let labels: [String?]
    /// The function this site called last, and whether its labels and arity fit this site: a site
    /// calls the same function nearly every time.
    @exclusivity(unchecked) var lastFunction: Function?
    @exclusivity(unchecked) var lastFits = false

    init(name: String?, callee: Expr, labels: [String?]) {
        self.name = name
        self.callee = callee
        self.labels = labels
    }
}

/// A pattern and where each name it binds goes.
final class PatternSite {
    let pattern: Pattern
    let slots: [(name: String, register: Register)]

    init(pattern: Pattern, slots: [(name: String, register: Register)]) {
        self.pattern = pattern
        self.slots = slots
    }
}

/// A stretch of code whose errors go somewhere else.
struct Handler {
    enum Catches {
        /// What `catch` catches: errors a script's `catch` sees.
        case runtimeErrors
        /// Any error: a `defer` runs however its block ends.
        case everything
    }

    var start: Int
    var end: Int
    var target: Int
    var catches: Catches
    /// Where the error's value (what `catch` binds) goes, if anywhere.
    var register: Register?
    /// Whether the error is kept for the code at `target` to throw again or hand on.
    var keepsError: Bool
    /// Whether it guards an expression (`try?`, `try!`) and not statements: the error has not left a
    /// statement yet, so it has not been told which one.
    var isExpression = false
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
    var expressions: [Expr] = []
    var callSites: [CallSite] = []
    var patterns: [PatternSite] = []
    var closures: [ClosureSite] = []
    var trees: [TreeNode] = []
    /// Assignments to what is not a local, which `assignByName` makes with the value it is given.
    var assignments: [Assignment] = []
    /// Innermost last: those that start later are inside those that start earlier.
    var handlers: [Handler] = []
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
