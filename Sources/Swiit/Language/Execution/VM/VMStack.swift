import Foundation

/// Where a frame is: the function, its code, its registers, and the next instruction.
struct VMCursor {
    var function: Function
    var code: Code
    var base: Int
    var pc: Int
    var statement: Int32
}

/// A caller's place while the function it called runs.
struct VMCaller {
    var code: Code
    var function: Function
    var pc: Int
    var base: Int
    var statement: Int32
    /// The register, counted from the stack's start, the callee's result goes to.
    var destination: Int
    /// The scopes the caller ran in, when it had a scope of its own (a method's `self`, a generic
    /// function's types) that is not what it captured; nil otherwise.
    var scopes: [Scope]?
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
