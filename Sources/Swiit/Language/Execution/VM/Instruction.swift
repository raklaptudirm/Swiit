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
    /// gave when it is an expression. A `try?` statement that gave nil failed, which the host is told.
    case finished(value: Register, isOptionalTry: Bool)

    // MARK: Values

    case loadConstant(dst: Register, constant: UInt32)
    case move(dst: Register, src: Register)
    /// A name looked up in the scopes: a global, a function, a type.
    case loadVariable(dst: Register, name: UInt32)
    /// `loadVariable` of a global, which finds the variable's cell once and keeps it while the names
    /// stay as they were.
    case loadGlobal(dst: Register, site: UInt32)
    /// `local[key] = value`, `local[key] op= value` and `local[key, default: d] op= value` of a list or a
    /// dictionary, where `local` is a register: the key is in `keys` and the default, if there is
    /// one, in the register after it. The next `offset` instructions, which do it the long way, are
    /// skipped when it was done.
    case assignElement(
        local: Register,
        keys: Register,
        hasDefault: Bool,
        op: BinaryOperator?,
        value: Register,
        offset: Int32
    )
    /// `assignElement` of a global, whose cell holds the list or the dictionary.
    case assignGlobalElement(
        global: UInt32,
        keys: Register,
        hasDefault: Bool,
        op: BinaryOperator?,
        value: Register,
        offset: Int32
    )
    /// A string with values interpolated: the text of the pieces, and what each value made of the
    /// registers from `first` on shows as.
    case interpolate(dst: Register, site: UInt32, first: Register)
    /// `p.a.b = v`, `xs[i][j] += v` and the like of a local, changed where it is when the tree
    /// evaluator's conditions for that hold (`plainPlace`): the keys of the path are in the registers
    /// from `keys`, in order, and the instruction after is jumped over. Otherwise the next one runs.
    case assignPath(local: Register, site: UInt32, keys: Register, value: Register, offset: Int32)
    /// `base[key]`: an element of a list, a dictionary or a string, or what a subscript of a struct or
    /// a class gives.
    case index(dst: Register, base: Register, key: Register)
    /// `base[key, default: …]` where the dictionary has the key: its value, and the instruction
    /// that works out the default is jumped over. Where it has not, the next instruction is run.
    case dictionaryValue(dst: Register, base: Register, key: Register, offset: Int32)
    /// A list of the `count` registers from `first`, which are let go of: the values of a literal.
    case makeList(dst: Register, first: Register, count: Register)
    /// A dictionary of the `count` pairs of registers from `first` (a key, then its value), which are
    /// let go of.
    case makeDictionary(dst: Register, first: Register, count: Register)
    /// A tuple of the registers from `first`, which are let go of, labeled as `Code.tuples[site]` says.
    case makeTuple(dst: Register, site: UInt32, first: Register)
    /// An error, its text `Code.names[message]`, if the register holds nil: `x!`.
    case requireValue(src: Register, message: UInt32)
    /// A value shown as text by its static type, `Code.types[type]`.
    case describe(dst: Register, src: Register, type: UInt32)
    /// `x as? T`, `x as! T`, `x is T` and `x as T`, with `Code.types[type]`.
    case cast(dst: Register, src: Register, type: UInt32, kind: CastKind)
    /// `fastMember` of a global list or string, read or changed in its cell.
    case fastGlobalMember(
        kind: FastMember,
        dst: Register,
        global: UInt32,
        argument: Register,
        offset: Int32
    )
    /// `assignMember` of a global struct or class instance, set in its cell.
    case assignGlobalMember(
        global: UInt32,
        site: UInt32,
        op: BinaryOperator?,
        value: Register,
        offset: Int32
    )
    /// A member of a Swift type that is not made by `fastMember`, run by the one routine the tree
    /// evaluator runs them with, with the receiver (`Register.max` for a static member) and arguments
    /// the loop has made already.
    case callBridged(dst: Register, site: UInt32, receiver: Register, arguments: Register)
    /// `assignMember` of `self`, whose cell is in `cell`: in a method that changes its receiver.
    case assignSelfMember(
        cell: Register,
        site: UInt32,
        op: BinaryOperator?,
        value: Register,
        offset: Int32
    )
    /// `local.name(arguments)` of a struct's method that is plain (not mutating, taking its arguments
    /// as written): run from the registers, without the tree evaluator's lookups and tables. The next
    /// `offset` instructions, which do it the long way, are skipped when it ran.
    case callMethod(
        dst: Register,
        site: UInt32,
        receiver: Register,
        arguments: Register,
        offset: Int32
    )
    /// `base.name`: a field of a struct is read where it is, and any other member by the one routine
    /// the tree evaluator reads them with.
    case loadMember(dst: Register, base: Register, name: UInt32, site: UInt32)
    /// `local.name = value` and `local.name op= value` of a stored field of a struct whose type lets
    /// it be set directly, to a value of the kind it holds; the next `offset` instructions, which do it
    /// the long way, are skipped then.
    case assignMember(
        local: Register,
        site: UInt32,
        op: BinaryOperator?,
        value: Register,
        offset: Int32
    )
    /// A member of a list or a string, made here when the receiver and argument are plainly of the
    /// kinds it knows; the next `offset` instructions, which make it the long way, are skipped then.
    case fastMember(
        kind: FastMember,
        dst: Register,
        receiver: Register,
        argument: Register,
        offset: Int32
    )
    /// An expression that names only globals and types, evaluated by the tree evaluator: `Oops.bad`.
    case evaluate(dst: Register, expression: UInt32)
    /// Sets `count` registers from `first` to nothing: the locals of a block that has ended.
    case clear(first: Register, count: Register)
    /// `dst` is `src` as the type says, or an error (`let x: Double = 1`).
    case conform(dst: Register, src: Register, type: UInt32)

    // MARK: Operators

    case binary(op: BinaryOperator, dst: Register, lhs: Register, rhs: Register)
    /// `binary` whose right operand is the integer written in it, so that a constant is not loaded.
    case binaryImmediate(op: BinaryOperator, dst: Register, lhs: Register, value: Int32)
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
    /// `jumpIfFalse` of a comparison of a register with an integer written in the code, in one
    /// instruction: `op` is one of the six comparisons.
    case jumpUnlessCompare(op: BinaryOperator, lhs: Register, value: Int32, offset: Int32)
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
    /// `assignByName` of a whole variable, which sets a number held in a number's cell directly and
    /// leaves the rest to the assignment.
    case assignGlobal(global: UInt32, site: UInt32, value: Register)

    // MARK: What the tree evaluator runs

    /// An expression the compiler does not compile, evaluated by the tree evaluator over a frame of
    /// the locals it mentions.
    case evaluateTree(dst: Register, node: UInt32)
    /// A statement it does not compile (an assignment through a path), run the same way.
    case runTree(node: UInt32)

    // MARK: Iteration

    /// `for x in s`: the iterator over a collection, a string, a dictionary or whatever `makeIterator`
    /// gives.
    case iterate(dst: Register, sequence: Register, awaiting: Bool)
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
    /// A failable initializer returns: when what it returns is nil (`return nil`, or a bare `return`),
    /// the construction failed. `Register.max` for a bare `return`.
    case failInit(Register)
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

    /// `accepts` for the value in a register, which is not copied to be looked at.
    @inline(__always)
    func accepts(at register: UnsafeMutablePointer<Value>) -> Bool {
        switch self {
        case .any: true
        case .int: if case .int = register.pointee.storage { true } else { false }
        case .double: if case .double = register.pointee.storage { true } else { false }
        case .bool: if case .bool = register.pointee.storage { true } else { false }
        case .string: if case .string = register.pointee.storage { true } else { false }
        case .other: false
        }
    }
}

/// What a function body compiled to.
final class Code {
    @exclusivity(unchecked) var instructions: [Instruction] = []
    /// The instructions again, in memory the loop reads without counting a reference: made by `seal`
    /// when the compiler is done, and alive as long as the code is.
    @exclusivity(unchecked) private(set) var program = UnsafeMutablePointer<Instruction>
        .allocate(capacity: 1)
    private var programCount = 1

    /// The compiler is done: `instructions` will not change.
    func seal() {
        looksUpNames = instructions.contains {
            switch $0 {
            case .evaluateTree, .runTree, .evaluate, .loadVariable, .assignByName, .makeClosure:
                true
            default: false
            }
        }
        program.deallocate()
        programCount = instructions.count
        program = .allocate(capacity: max(1, programCount))
        program.initialize(from: instructions, count: programCount)
        callSiteTable.deallocate()
        callSiteTable = .allocate(capacity: max(1, callSites.count))
        callSiteTable.initialize(
            from: callSites.map(Unmanaged.passUnretained),
            count: callSites.count
        )
        kindTable.deallocate()
        kindTable = .allocate(capacity: max(1, parameterKinds.count))
        kindTable.initialize(from: parameterKinds, count: parameterKinds.count)
    }

    deinit {
        program.deallocate()
        callSiteTable.deallocate()
        kindTable.deallocate()
    }
    @exclusivity(unchecked) var constants: [Value] = []
    @exclusivity(unchecked) var names: [String] = []
    @exclusivity(unchecked) var types: [TypeExpression] = []
    @exclusivity(unchecked) var expressions: [Expr] = []
    @exclusivity(unchecked) var callSites: [CallSite] = []
    @exclusivity(unchecked) var members: [MemberSite] = []
    @exclusivity(unchecked) var methods: [MethodSite] = []
    @exclusivity(unchecked) var bridgedSites: [BridgedSite] = []
    @exclusivity(unchecked) var strings: [StringSite] = []
    /// The labels of each tuple literal's elements, nil where an element has none.
    @exclusivity(unchecked) var tuples: [[String?]] = []
    /// The places `assignPath` changes.
    @exclusivity(unchecked) var paths: [PathSite] = []
    @exclusivity(unchecked) var globals: [GlobalSite] = [] {
        didSet { globalTable = globals.map(Unmanaged.passUnretained) }
    }
    /// `globals`, read without counting a reference.
    @exclusivity(unchecked) private(set) var globalTable: [Unmanaged<GlobalSite>] = []
    /// `callSites`, read without counting a reference: the sites are kept alive by `callSites`.
    @exclusivity(unchecked) private(set) var callSiteTable =
        UnsafeMutablePointer<Unmanaged<CallSite>>.allocate(capacity: 1)
    /// `parameterKinds`, in memory the loop reads without counting a reference: made by `seal`.
    @exclusivity(unchecked) private(set) var kindTable =
        UnsafeMutablePointer<ParameterKind>.allocate(capacity: 1)
    @exclusivity(unchecked) var patterns: [PatternSite] = []
    @exclusivity(unchecked) var closures: [ClosureSite] = []
    @exclusivity(unchecked) var trees: [TreeNode] = []
    /// Assignments to what is not a local, which `assignByName` makes with the value it is given.
    @exclusivity(unchecked) var assignments: [Assignment] = []
    /// Innermost last: those that start later are inside those that start earlier.
    @exclusivity(unchecked) var handlers: [Handler] = []
    /// The source range of each statement a `step` or `at` names; nil where the program had none.
    @exclusivity(unchecked) var ranges: [SourceRange?] = []
    /// How many registers a run of it uses: the locals the frame resolver counted, then temporaries.
    @exclusivity(unchecked) var frameSize = 0
    @exclusivity(unchecked) var parameterCount = 0
    /// What each parameter asks of an argument, for the common types a call can check at a glance.
    @exclusivity(unchecked) var parameterKinds: [ParameterKind] = []
    /// What the function says it gives back, when a result of that kind needs no `conform`.
    @exclusivity(unchecked) var returnKind = ParameterKind.any
    /// The body is one expression that is the result (a closure's, or a short function's), which the
    /// tree evaluator runs without counting a statement: so does the VM.
    @exclusivity(unchecked) var isImplicitReturn = false
    /// The VM's loop may call it with the arguments as written, in registers, and it runs in the
    /// scopes it captured: false for what has a scope of its own (a method's `self`, a generic
    /// function's types) and for what binds its arguments in a way of its own (a variadic parameter
    /// gathers them in a list, an `@autoclosure` one wraps the argument).
    @exclusivity(unchecked) var isPlain = true
    /// Its arguments are taken as written, in registers, whether or not it changes its receiver: what a
    /// method the loop calls itself must be.
    @exclusivity(unchecked) var takesArgumentsAsWritten = true
    /// The register that holds the cell of `self`, for a body that names it: filled as the call
    /// begins, so that it is not looked up by name each time. Such code is entered by a call that has
    /// the receiver, never by the loop's own.
    @exclusivity(unchecked) var selfRegister: Register?
    /// The body of a method (not an initializer) that names `self`: it runs in the scopes its
    /// function captured, and the scope that binds `self` by name is made when something looks for it
    /// (`Interpreter.ensureSelfScope`).
    @exclusivity(unchecked) var isMethodBody = false
    /// The same for an initializer, whose `self` is `.initializing`.
    @exclusivity(unchecked) var isInitializerBody = false
    /// Something in it looks names up in the scopes: a tree node, an evaluation by name, a closure.
    @exclusivity(unchecked) private(set) var looksUpNames = false
    /// An initializer that may fail, whose `return nil` ends the construction.
    @exclusivity(unchecked) var isFailable = false
    /// A statement of a program's own code, not a function: it is no call, so it adds no entry to an
    /// error's calls and no depth to the call stack.
    @exclusivity(unchecked) var isProgram = false
}
