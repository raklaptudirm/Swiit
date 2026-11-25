import Foundation

/// Where a frame is: the function, its code, its registers, and the next instruction.
struct VMCursor {
    // Not counted: the frame that is running is held by the `VMCaller` above it (or by the entry).
    unowned(unsafe) var function: Function
    unowned(unsafe) var code: Code
    var base: Int
    var pc: Int
    var statement: Int32
}

/// What a call site calls, found without leaving the loop.
struct VMTarget {
    let function: Function
    let code: Code
    /// It runs in the scopes the caller does, which are then left as they are.
    let sharesScopes: Bool
}

/// A caller's place while the function it called runs.
struct VMCaller {
    // Not counted: the caller is held by the frame under this one, or is the entry.
    unowned(unsafe) var code: Code
    unowned(unsafe) var function: Function
    /// The function this call runs, which keeps it alive while it does: the loop does not count the
    /// function it is in.
    var callee: Function
    var pc: Int
    var base: Int
    var statement: Int32
    /// The register, counted from the stack's start, the callee's result goes to.
    var destination: Int
    /// The scopes the caller ran in, when it had a scope of its own (a method's `self`, a generic
    /// function's types) that is not what it captured; nil otherwise.
    var scopes: [Scope]?
    /// The call left the scopes as they were, so returning leaves them so.
    var sameScopes = false
    /// A method the loop called with a scope of its own: its `MethodExit` is the last of `methodExits`.
    var isMethod = false
}

/// What returning from a method the loop called undoes besides leaving its frame. A class, so that the
/// record of a call that is not one is a word.
final class MethodExit {
    /// The cell of `self` in the scope of the call, which the receiver is read back from.
    let selfCell: Binding.Cell
    /// The call pushed the class whose body it is, for `super`.
    let popsOwner: Bool
    /// The register, counted from the stack's start, a struct the method changed is stored back in;
    /// negative where it is not.
    let storeReceiverAt: Int

    init(selfCell: Binding.Cell, popsOwner: Bool, storeReceiverAt: Int) {
        self.selfCell = selfCell
        self.popsOwner = popsOwner
        self.storeReceiverAt = storeReceiverAt
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
    @exclusivity(unchecked) var callers: [VMCaller] = []
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

/// A method the loop is to call: what the site found, and whether its receiver is a class's instance.
struct MethodTarget {
    let function: Function
    let code: Code
    let isClass: Bool
    /// The arguments to place, when the call leaves out parameters that have defaults.
    let mapping: [Int]?
}
