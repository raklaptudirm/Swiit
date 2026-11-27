import Foundation
import SwiftSyntax

/// What the loop reads of a function's code as it calls it or returns from it, as plain values: taken
/// from the code in one step, so that Swift does not count the code to read each of them.
struct CodeFacts {
    let kinds: UnsafeMutablePointer<ParameterKind>
    let parameterCount: Int
    let frameSize: Int
    let program: UnsafeMutablePointer<Instruction>
    let returnKind: ParameterKind
    /// The method sites of the code, by index.
    let methods: UnsafeMutablePointer<Unmanaged<MethodSite>>
    /// How many scopes its function captured.
    let capturedCount: Int
    /// The register of `self`, or -1 for a body that does not name it.
    let selfRegister: Int
    /// The register of `self` when it holds the struct itself (`SelfStorage.inPlace`), which the end of
    /// the frame takes the value from; -1 otherwise.
    let inPlaceSelf: Int
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
        isLeaf =
            selfRegister == nil && handlers.isEmpty
            && instructions.allSatisfy {
                switch $0 {
                case .move, .loadConstant, .binary, .binaryImmediate, .unary, .shortCircuit,
                    .needBool, .jump, .jumpIfFalse, .jumpIfTrue, .jumpUnlessCompare, .jumpIfNil,
                    .jumpIfNotNil, .loadMember, .returnValue, .returnNothing, .at:
                    true
                default: false
                }
            }
        looksUpNames = instructions.contains {
            switch $0 {
            case .fallback, .captures(.makeClosure):
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
        methodTable.deallocate()
        methodTable = .allocate(capacity: max(1, methods.count))
        methodTable.initialize(from: methods.map(Unmanaged.passUnretained), count: methods.count)
        facts = CodeFacts(
            kinds: kindTable,
            parameterCount: parameterCount,
            frameSize: frameSize,
            program: program,
            returnKind: returnKind,
            methods: methodTable,
            capturedCount: capturedCount,
            selfRegister: selfRegister.map(Int.init) ?? -1,
            inPlaceSelf: {
                if case .inPlace(let register, _) = selfStorage { Int(register) } else { -1 }
            }()
        )
    }

    deinit {
        program.deallocate()
        callSiteTable.deallocate()
        kindTable.deallocate()
        methodTable.deallocate()
    }
    @exclusivity(unchecked) var constants: [Value] = []
    @exclusivity(unchecked) var names: [String] = []
    @exclusivity(unchecked) var types: [TypeExpression] = []
    @exclusivity(unchecked) var expressions: [Expr] = []
    @exclusivity(unchecked) var callSites: [CallSite] = []
    @exclusivity(unchecked) var members: [MemberSite] = []
    @exclusivity(unchecked) var methods: [MethodSite] = []
    @exclusivity(unchecked) private(set) var methodTable =
        UnsafeMutablePointer<Unmanaged<MethodSite>>.allocate(capacity: 1)
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
    @exclusivity(unchecked) var destructures: [DestructureSite] = []
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
    /// What the loop reads of it, made by `seal` when the compiler is done.
    @exclusivity(unchecked) private(set) var facts: CodeFacts

    init() {
        facts = CodeFacts(
            kinds: kindTable,
            parameterCount: 0,
            frameSize: 0,
            program: program,
            returnKind: .any,
            methods: methodTable,
            capturedCount: 0,
            selfRegister: -1,
            inPlaceSelf: -1
        )
    }
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
    /// How the body holds `self`, if it names it.
    @exclusivity(unchecked) var selfStorage = SelfStorage.none
    /// Its instructions only read registers, constants and the stored fields of what they hold, compute
    /// with them, jump forward and return: no call, no write outside the frame, no name looked up. A
    /// native body that calls it may run it by `Interpreter.runLeaf`, which gives up (and the call is
    /// made as any is) at anything it does not do itself, so it need undo nothing.
    @exclusivity(unchecked) private(set) var isLeaf = false
    /// How many scopes its function captured, which are the task's while it runs.
    @exclusivity(unchecked) var capturedCount = 0
    /// The body names `super`, which needs the class it belongs to pushed as it is called.
    @exclusivity(unchecked) var usesSuper = false
    /// Its function belongs to a class, which a call pushes for `super`.
    @exclusivity(unchecked) var hasOwner = false
    /// Something in it looks names up in the scopes: a tree node, an evaluation by name, a closure.
    @exclusivity(unchecked) private(set) var looksUpNames = false
    /// An initializer that may fail, whose `return nil` ends the construction.
    @exclusivity(unchecked) var isFailable = false
    /// A statement of a program's own code, not a function: it is no call, so it adds no entry to an
    /// error's calls and no depth to the call stack.
    @exclusivity(unchecked) var isProgram = false
}

extension Code {
    /// How a body that names `self` holds it: in a register of its own after the locals, filled as the
    /// call begins, so that it is not looked up by name each time. Such code is entered by a call that
    /// has the receiver, never by the loop's own. The scope that binds `self` by name is made only when
    /// something looks for it (`Interpreter.ensureSelfScope`).
    enum SelfStorage {
        /// The body does not name `self`.
        case none
        /// The receiver as it is, and no cell: a method that does not change `self` (a struct's, an
        /// enum's or an extension's), or a class's method that does not name `super`.
        case value(Register)
        /// The cell of `self`, through which what the body changes goes back to the receiver: a method
        /// that changes it or names `super`, and a closure in a method.
        case cell(Register)
        /// The cell of the value an initializer makes, whose `self` is `.initializing`.
        case initializing(Register)
        /// The struct itself, changed where it is in the register: a struct's mutating method, or its
        /// initializer (`initializes`), with no closure or nested function that could keep the scope
        /// of `self` past the instruction that made it. What looks `self` up by name has the value in
        /// that scope's cell while it runs, and back in the register after
        /// (`Interpreter.withSelfInScope`).
        case inPlace(Register, initializes: Bool)

        /// The register of `self`, if the body names it.
        var register: Register? {
            switch self {
            case .none: nil
            case .value(let register), .cell(let register), .initializing(let register),
                .inPlace(let register, _):
                register
            }
        }

        /// The register holds a cell of `self`, not its value.
        var holdsCell: Bool {
            switch self {
            case .cell, .initializing: true
            case .none, .value, .inPlace: false
            }
        }
    }

    /// The register of `self`, if the body names it.
    var selfRegister: Register? { selfStorage.register }
}
