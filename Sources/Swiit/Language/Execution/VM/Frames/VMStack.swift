import Foundation

/// Where a frame is: the function, its code, its registers, and the next instruction.
struct VMCursor {
    // Not counted: the frame that is running is held by the `VMCaller` above it (or by the entry).
    unowned(unsafe) var function: Function
    unowned(unsafe) var code: Code
    var base: Int
    var pc: Int
    var statement: Int32

    /// The function and its code, uncounted.
    var refs: (Unmanaged<Function>, Unmanaged<Code>) {
        (.passUnretained(function), .passUnretained(code))
    }
}

/// What a call site calls, found without leaving the loop.
struct VMTarget {
    let function: Function
    let code: Code
    /// It runs in the scopes the caller does, which are then left as they are.
    let sharesScopes: Bool
}

/// A caller's place while the function it called runs. It holds no Swift references that are counted,
/// so pushing and popping one is a copy of plain words; the function it calls is retained by hand,
/// and `releaseCallee` lets it go.
struct VMCaller {
    // Not counted: the caller is held by the frame under this one, or is the entry.
    let codeRef: Unmanaged<Code>
    let functionRef: Unmanaged<Function>
    /// The function this call runs, retained, which keeps it alive while it does: the loop does not
    /// count the function it is in.
    let calleeRef: Unmanaged<Function>
    var pc: Int
    var base: Int
    var statement: Int32
    /// The register, counted from the stack's start, the callee's result goes to.
    var destination: Int
    /// The scopes the caller ran in were kept in `VMStack.savedScopes`: it had scopes of its own (a
    /// method's `self`, a generic function's types) that are not what it captured.
    var hasScopes = false
    /// The call left the scopes as they were, so returning leaves them so.
    var sameScopes = false
    /// A method the loop called with a scope of its own: its `MethodExit` is the last of `methodExits`.
    var isMethod = false

    /// A record made from references the loop already holds uncounted, which keeps Swift from
    /// counting them again.
    init(
        codeRef: Unmanaged<Code>,
        functionRef: Unmanaged<Function>,
        calleeRef: Unmanaged<Function>,
        pc: Int,
        base: Int,
        statement: Int32,
        destination: Int,
        sameScopes: Bool = false
    ) {
        self.codeRef = codeRef
        self.functionRef = functionRef
        self.calleeRef = calleeRef.retain()
        self.pc = pc
        self.base = base
        self.statement = statement
        self.destination = destination
        self.sameScopes = sameScopes
    }

    init(
        code: Code,
        function: Function,
        callee: Function,
        pc: Int,
        base: Int,
        statement: Int32,
        destination: Int,
        sameScopes: Bool = false,
        isMethod: Bool = false
    ) {
        codeRef = .passUnretained(code)
        functionRef = .passUnretained(function)
        calleeRef = .passRetained(callee)
        self.pc = pc
        self.base = base
        self.statement = statement
        self.destination = destination
        self.sameScopes = sameScopes
        self.isMethod = isMethod
    }

    var code: Code { codeRef.takeUnretainedValue() }
    var function: Function { functionRef.takeUnretainedValue() }
    var callee: Function { calleeRef.takeUnretainedValue() }

    /// The call is over: what the record held of its callee is let go.
    func releaseCallee() { calleeRef.release() }
}

/// What returning from a method or an initializer the loop called undoes besides leaving its frame.
struct MethodExit {
    /// The cell of `self`, which the receiver or the value made is read back from; nil for a body that
    /// holds `self` as a value or does not name it.
    let selfCell: Binding.Cell?
    /// The call pushed the class whose body it is, for `super`.
    let popsOwner: Bool
    let ending: Ending

    /// What the frame's end gives: a method's, nothing but what goes back to its receiver; an
    /// initializer's, the value it made.
    enum Ending {
        case method(WriteBack)
        case initializer(Completion)
    }

    /// Where a struct a method changed goes back to: what the receiver was moved out of, so that the
    /// cell of `self` held it alone. Changes are kept whether the method returns or fails, as Swift
    /// keeps them.
    enum WriteBack {
        /// Nothing goes back: a method that does not change its receiver, or a class's.
        case none
        /// The register, counted from the stack's start, the receiver was in.
        case register(Int)
        /// The cell of the global, or of the caller's `self`, the receiver was in.
        case cell(Binding.Cell)

        /// Something goes back: the receiver was moved out of where it was.
        var changesReceiver: Bool {
            if case .none = self { false } else { true }
        }

        /// Puts `value` where the receiver came from.
        func store(_ value: Value, on stack: VMStack) {
            switch self {
            case .none: break
            case .register(let register): stack.base[register] = value
            case .cell(let cell): cell.value = value
            }
        }
    }

    /// The value a constructor's frame gives back in place of the initializer's result.
    enum Completion {
        /// A struct, its fields put in the order the type declares them.
        case structValue(StructType)
        /// A class's instance, which the initializer's superclass part completes; what `calledSuperInit`
        /// was before the call, which is put back.
        case classInstance(ClassInstance, Function, savedSuperInit: Bool)
    }
}

/// The registers of a task's compiled code, one frame after another, and where each caller was. A
/// frame's registers are a window of it, so a call makes nothing: the arguments are written where the
/// callee's parameters are.
final class VMStack {
    private(set) var base: UnsafeMutablePointer<Value>
    private(set) var capacity: Int
    /// The first register no frame uses.
    @exclusivity(unchecked) var top = 0
    let callers = CallerStack()
    /// The scopes of the callers that had scopes of their own, innermost last.
    @exclusivity(unchecked) var savedScopes: [[Scope]] = []
    /// Emptied argument arrays of bridged calls, with their storage, so that a call takes one
    /// instead of allocating; one is out for each bridged call that has not returned.
    @exclusivity(unchecked) var argumentArrays: [[Value]] = []

    /// What the methods the loop is in the middle of calling undo as they return, innermost last.
    @exclusivity(unchecked) var methodExits: [MethodExit] = []
    /// Errors a handler caught, kept for the code it jumped to: the last is the one it is about.
    var caught: [Error] = []
    /// What `observesStatements` was before each deferred block that is running began.
    var quiet: [Bool] = []

    init() {
        capacity = 1 << 12
        base = .allocate(capacity: capacity)
        base.initialize(repeating: .nothing, count: capacity)
    }

    deinit {
        base.deinitialize(count: capacity)
        base.deallocate()
    }

    /// Whether a register holds a struct of the type `type`, or an instance of the class `klass`: the
    /// receiver a method site found its method for. The value is not copied to be looked at.
    @inline(__always)
    static func receiverFits(
        at register: UnsafeMutablePointer<Value>,
        struct type: TypeRef?,
        instance klass: ObjectIdentifier?
    ) -> Bool {
        switch register.pointee.storage {
        case .structure(let structure):
            return type != nil && structure.typeRefIfAny == type
        case .object(let object):
            guard let klass,
                ObjectIdentifier(Swift.type(of: object)) == ObjectIdentifier(ClassInstance.self)
            else { return false }
            return ObjectIdentifier(unsafeDowncast(object, to: ClassInstance.self).type) == klass
        default:
            return false
        }
    }

    /// The integer in a register, which is not copied to be looked at.
    @inline(__always)
    static func integer(at register: UnsafeMutablePointer<Value>) -> Int? {
        if case .int(let number) = register.pointee.storage { return number }
        return nil
    }

    /// `value` into a register. One that holds a number, a Bool or nothing has nothing to let go,
    /// and is written over as it is.
    @inline(__always)
    static func put(_ value: Value, at register: UnsafeMutablePointer<Value>) {
        switch register.pointee.storage {
        case .nothing, .bool, .int, .double: register.initialize(to: value)
        default: register.pointee = value
        }
    }

    /// The registers `first..<first + count` let go. One that holds a number, a Bool or nothing holds no
    /// reference, and is left as it is.
    @inline(__always)
    static func clear(_ first: UnsafeMutablePointer<Value>, count: Int) {
        for index in 0..<count {
            switch first[index].storage {
            case .nothing, .bool, .int, .double: continue
            default: first[index] = .nothing
            }
        }
    }

    /// A caller's record, and the scopes it ran in when they are not what it captured.
    @inline(__always)
    func push(_ caller: VMCaller, scopes: [Scope]? = nil) {
        var record = caller
        if let scopes {
            savedScopes.append(scopes)
            record.hasScopes = true
        }
        callers.append(record)
    }

    /// The struct in a register, and in the cell of the global it was loaded from, if it was, moved into
    /// a cell that holds it alone while a method changes it. The exit puts it back where it came from
    /// as the method returns or fails.
    func moveReceiverIntoCell(at register: Int, of global: Binding.Cell?) -> Binding.Cell {
        let cell = Binding.Cell(base[register])
        base[register] = .nothing
        global?.value = .nothing
        methodExits.append(
            MethodExit(
                selfCell: cell,
                popsOwner: false,
                ending: .method(global.map(MethodExit.WriteBack.cell) ?? .register(register))
            )
        )
        return cell
    }

    /// Room for `needed` registers. A stack that grows moves, so a pointer into it is taken again
    /// afterward.
    func ensure(_ needed: Int) {
        guard needed > capacity else { return }
        var larger = capacity
        while larger < needed { larger *= 2 }
        let moved = UnsafeMutablePointer<Value>.allocate(capacity: larger)
        moved.moveInitialize(from: base, count: capacity)
        (moved + capacity).initialize(repeating: .nothing, count: larger - capacity)
        base.deallocate()
        base = moved
        capacity = larger
    }
}

/// The records of the callers of the frames that are running, in memory the loop pushes and pops
/// without the checks an array makes (that its buffer is its own, and has room).
final class CallerStack {
    private var records = UnsafeMutablePointer<VMCaller>.allocate(capacity: 64)
    private var capacity = 64
    private(set) var count = 0

    deinit {
        for index in 0..<count { records[index].releaseCallee() }
        records.deallocate()
    }

    @inline(__always)
    func append(_ caller: VMCaller) {
        if count == capacity { grow() }
        (records + count).initialize(to: caller)
        count += 1
    }

    @inline(__always)
    func removeLast() -> VMCaller {
        count -= 1
        return records[count]
    }

    private func grow() {
        let larger = UnsafeMutablePointer<VMCaller>.allocate(capacity: capacity * 2)
        larger.moveInitialize(from: records, count: count)
        records.deallocate()
        records = larger
        capacity *= 2
    }
}
