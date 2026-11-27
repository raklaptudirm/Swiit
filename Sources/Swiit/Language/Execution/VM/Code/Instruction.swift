import Foundation

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

    /// `loadVariable` of a global, which finds the variable's cell once and keeps it while the names
    /// stay as they were.
    case loadGlobal(dst: Register, site: UInt32)

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

    /// Sets `count` registers from `first` to nothing: the locals of a block that has ended.
    case clear(first: Register, count: Register)

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

    case jumpIfNil(register: Register, offset: Int32)

    // MARK: Errors

    /// An error `Code.handlers` caught is dealt with: kept by the clause that took it, thrown again
    /// when none did, thrown as a fatal one for `try!`, or told to the host for a `defer` that failed.
    case caughtTaken

    case rethrow

    // MARK: Deferred blocks

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

    case storeCell(box: Register, src: Register)

    case assignCell(box: Register, op: BinaryOperator, value: Register)

    /// `assignByName` of a whole variable, which sets a number held in a number's cell directly and
    /// leaves the rest to the assignment.
    case assignGlobal(global: UInt32, site: UInt32, value: Register)

    // MARK: What the tree evaluator runs

    // MARK: Iteration

    /// The next element into `variable`, or a jump out of the loop.
    case iterateNext(iterator: Register, variable: Register, exit: Int32)

    // MARK: Calls

    /// Calls what `Code.callSites[site]` names with the arguments in the registers from `arguments`.
    /// A script function that compiled takes them where they are: they are its first registers.
    case call(dst: Register, site: UInt32, arguments: Register)

    /// Calls the function in a register (a closure, or a parameter of function type).
    case callValue(dst: Register, callee: Register, site: UInt32, arguments: Register)

    case returnValue(Register)

    case returnNothing

    // MARK: Handed off

    // What the loop hands to the executor of the family, off its common path (`executeHandedOff`).
    case members(Members)
    case collections(Collections)
    case conversions(Conversions)
    case patterns(Patterns)
    case iteration(Iteration)
    case errors(Errors)
    case fallback(Fallback)
    case captures(Captures)
    case calls(Calls)
}

extension Instruction {
    /// The fields of structs and instances, read and set where they are.
    enum Members {
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

        /// `assignMember` of `self`, whose cell is in `cell`: in a method that changes its receiver.
        case assignSelfMember(
            cell: Register,
            site: UInt32,
            op: BinaryOperator?,
            value: Register,
            offset: Int32
        )

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
    }

    /// Lists, dictionaries and tuples: made from registers, read by index or key, and changed where
    /// they are.
    enum Collections {
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

        /// `p.a.b = v`, `xs[i][j] += v` and the like of a local, changed where it is when the tree
        /// evaluator's conditions for that hold (`plainPlace`): the keys of the path are in the registers
        /// from `keys`, in order, and the instruction after is jumped over. Otherwise the next one runs.
        case assignPath(
            local: Register,
            site: UInt32,
            keys: Register,
            value: Register,
            offset: Int32
        )

        /// `base[key]`: an element of a list, a dictionary or a string, or what a subscript of a struct or
        /// a class gives.
        case index(dst: Register, base: Register, key: Register)

        /// `base[key, default: …]` where the dictionary has the key: its value, and the instruction
        /// that works out the default is jumped over. Where it has not, the next instruction is run.
        case dictionaryValue(dst: Register, base: Register, key: Register, offset: Int32)

        /// A list of the `count` registers from `first`, which are let go of: the values of a literal.
        case makeList(dst: Register, first: Register, count: Register)

        /// `xs += [a, b]`: the `count` registers from `first`, which are let go of, are added to the list in
        /// `local` where it is, and no list is made of them; to anything else, a list of them is added as
        /// `+=` adds one.
        case appendValues(local: Register, first: Register, count: Register)

        /// A dictionary of the `count` pairs of registers from `first` (a key, then its value), which are
        /// let go of.
        case makeDictionary(dst: Register, first: Register, count: Register)

        /// A tuple of the registers from `first`, which are let go of, labeled as `Code.tuples[site]` says.
        case makeTuple(dst: Register, site: UInt32, first: Register)
    }

    /// A value made a value of another kind or type: interpolated into text, unwrapped, described,
    /// cast or conformed.
    enum Conversions {
        /// A string with values interpolated: the text of the pieces, and what each value made of the
        /// registers from `first` on shows as.
        case interpolate(dst: Register, site: UInt32, first: Register)

        /// An error, its text `Code.names[message]`, if the register holds nil: `x!`.
        case requireValue(src: Register, message: UInt32)

        /// A value shown as text by its static type, `Code.types[type]`.
        case describe(dst: Register, src: Register, type: UInt32)

        /// `x as? T`, `x as! T`, `x is T` and `x as T`, with `Code.types[type]`.
        case cast(dst: Register, src: Register, type: UInt32, kind: CastKind)

        /// `dst` is `src` as the type says, or an error (`let x: Double = 1`).
        case conform(dst: Register, src: Register, type: UInt32)
    }

    /// Matching a value to a pattern, and the `where` and the `default` of a `switch`.
    enum Patterns {
        /// Matches the value against the pattern `Code.patterns[pattern]`, as the tree evaluator does:
        /// the names it binds go to their registers, or the code jumps by `fail`.
        case match(pattern: UInt32, value: Register, fail: Int32)

        /// A tuple of the size `Code.destructures[site]` says, as the element of a `for` is matched to
        /// `(a, b)`: each name's register gets the field at its position, and the instruction after (the
        /// general `match`) is jumped over. Where the value is not that, the next instruction runs.
        case destructure(site: UInt32, value: Register, offset: Int32)

        /// A `case`'s `where`: jumps when it is false, and it must be a Bool.
        case jumpIfWhereFalse(condition: Register, offset: Int32)

        /// A switch whose cases none matched.
        case noMatch(value: Register)
    }

    /// A `for` over a collection, a dictionary or an iterator.
    enum Iteration {
        /// `for x in s`: the iterator over a collection, a string, a dictionary or whatever `makeIterator`
        /// gives.
        case iterate(dst: Register, sequence: Register, awaiting: Bool)

        /// `for (k, v) in d` with names for the pieces: `iterate` for a source that may be a dictionary,
        /// which then keeps its keys in `dst` and its values in the register `dst + 3`, and no tuple is
        /// made for any entry.
        case iteratePairs(dst: Register, sequence: Register)

        /// `iterateNext` for `iteratePairs`: where the iteration holds a dictionary, its next key and value go
        /// to the registers `Code.destructures[site]` names and the pc moves on by `skip`, over the
        /// destructuring and the match that follow; otherwise the element goes into `variable`, as
        /// `iterateNext` does.
        case iterateNextPair(
            iterator: Register,
            variable: Register,
            site: UInt32,
            exit: Int32,
            skip: Int32
        )

        /// An element that did not fit the pattern of a `for`.
        case iterationMismatch(element: Register)
    }

    /// Errors thrown, reported or made fatal, and the deferred blocks that run as they leave.
    enum Errors {
        /// `throw value`.
        case throwValue(Register)

        case fatalize

        case reportDeferred

        /// `guard`'s `else` did not leave.
        case guardCarriedOn

        /// A block with `defer`s keeps in a register which of them it has reached: this one is.
        case deferMark(register: Register, bit: UInt8)
    }

    /// What the general path does: a name looked up in the scopes, an expression or a statement run
    /// by the tree evaluator, and an assignment by name.
    enum Fallback {
        /// A name looked up in the scopes: a global, a function, a type.
        case loadVariable(dst: Register, name: UInt32)

        /// An expression that names only globals and types, evaluated by the tree evaluator: `Oops.bad`.
        case evaluate(dst: Register, expression: UInt32)

        /// Assigns a variable that is not a local, by name: a global, or one a closure captured.
        case assignByName(site: UInt32, value: Register)

        /// An expression the compiler does not compile, evaluated by the tree evaluator over a frame of
        /// the locals it mentions.
        case evaluateTree(dst: Register, node: UInt32)

        /// A statement it does not compile (an assignment through a path), run the same way.
        case runTree(node: UInt32)
    }

    /// Closures, and the variables they capture that hold a reference weakly.
    enum Captures {
        /// A `weak` or `unowned` variable is read as what it refers to, or nil once that is gone.
        case derefWeak(register: Register)

        /// The closure `Code.closures[site]` made of the cells and values it captures.
        case makeClosure(dst: Register, site: UInt32)
    }

    /// Calls of the members of Swift's types, the arguments an `inout` parameter hands back, and an
    /// initializer that fails.
    enum Calls {
        /// A member of a Swift type that is not made by `fastMember`, run by the one routine the tree
        /// evaluator runs them with, with the receiver (`Register.max` for a static member) and arguments
        /// the loop has made already.
        case callBridged(dst: Register, site: UInt32, receiver: Register, arguments: Register)

        /// What the `inout` parameters hold as the function ends, for the call to hand back.
        case inoutOutputs(first: Register, count: UInt16)

        /// The register is what the call left in its `index`th `inout` parameter.
        case takeInout(dst: Register, index: UInt16)

        case finishInout

        /// A failable initializer returns: when what it returns is nil (`return nil`, or a bare `return`),
        /// the construction failed. `Register.max` for a bare `return`.
        case failInit(Register)
    }
}
