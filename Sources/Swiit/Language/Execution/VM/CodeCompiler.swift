import Foundation

/// A body the compiler does not handle (yet): the function it is in keeps running on the tree
/// evaluator. `reason` says what stopped it, for the progress count.
struct Unsupported: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Compiles a function body to `Code`. It takes what the tree evaluator runs, after the checker and
/// the frame resolver, and handles the part of the language the slices of `Docs/vm.md` have reached:
/// locals in registers, operators, calls by name, `if`, `guard`, `switch`, `while`, `for` over a
/// range, `break`, `continue`, `fallthrough`, `return`, `throw`, `try`, `do`/`catch` and `defer`.
/// Anything else throws `Unsupported`.
///
/// It is split over four files by what it compiles: this one is the state and the function,
/// `+Statements` the blocks and loops, `+ControlFlow` the choices and errors, `+Expressions`
/// the values.
struct CodeCompiler {
    struct Local {
        let slot: Register
        let mutable: Bool
    }

    struct Scope {
        var locals: [String: Local] = [:]
        /// The registers its block declares, cleared when the block ends.
        var cleared: (first: Register, count: Register)?
        /// The `defer`s of its block, and the register that says which of them it has reached.
        var defers: [Program] = []
        var deferMask: Register?
        var deferred = 0
    }

    /// A loop or a switch: where `break` and `continue` go.
    struct Breakable {
        let label: String?
        let isSwitch: Bool
        /// How many scopes were open outside its body.
        let scopeDepth: Int
        /// Where `continue` goes, when that is known before the body is compiled.
        var continueTarget: Int?
        var continues: [Int] = []
        var breaks: [Int] = []
        /// A switch case's `fallthrough`s, which go to the next case's body.
        var fallthroughs: [Int] = []
    }

    var code = Code()
    var scopes: [Scope] = []
    var breakables: [Breakable] = []
    var nextTemporary = 0
    var highest = 0

    /// The code for `function`, or why it is not one the VM runs.
    static func compile(_ function: Function) -> Result<Code, Unsupported> {
        guard function.isCompilable, case .swiit(let body) = function.body,
            let frameSize = body.frameSize
        else { return .failure(Unsupported("not a plain function of the global scopes")) }
        var compiler = CodeCompiler()
        do {
            try compiler.function(function, body, frameSize: frameSize)
        } catch let unsupported as Unsupported {
            return .failure(unsupported)
        } catch {
            return .failure(Unsupported("\(error)"))
        }
        return .success(compiler.code)
    }

    private mutating func function(_ function: Function, _ body: Program, frameSize: Int) throws {
        nextTemporary = frameSize
        highest = max(frameSize, function.parameters.count) - 1
        code.parameterCount = function.parameters.count
        code.parameterKinds = function.parameters.map { ParameterKind($0.type) }
        var parameters = Scope()
        for (slot, parameter) in function.parameters.enumerated() where parameter.name != "_" {
            parameters.locals[parameter.name] = Local(slot: Register(slot), mutable: false)
        }
        scopes = [parameters]
        if let expression = function.implicitReturn {
            code.isImplicitReturn = true
            let result = try operand(expression)
            emit(.returnValue(result))
        } else {
            try contents(of: body)
            emit(.returnNothing)
        }
        code.frameSize = highest + 1
    }

    // MARK: Emitting

    @discardableResult
    mutating func emit(_ instruction: Instruction) -> Int {
        code.instructions.append(instruction)
        return code.instructions.count - 1
    }

    var here: Int { code.instructions.count }

    /// Makes the jump at `index` land on `target`.
    mutating func patch(_ index: Int, to target: Int) {
        let offset = Int32(target - (index + 1))
        switch code.instructions[index] {
        case .jump: code.instructions[index] = .jump(offset: offset)
        case .jumpIfFalse(let condition, _):
            code.instructions[index] = .jumpIfFalse(condition: condition, offset: offset)
        case .jumpIfTrue(let condition, _):
            code.instructions[index] = .jumpIfTrue(condition: condition, offset: offset)
        case .jumpIfWhereFalse(let condition, _):
            code.instructions[index] = .jumpIfWhereFalse(condition: condition, offset: offset)
        case .shortCircuit(let op, let register, _):
            code.instructions[index] = .shortCircuit(op: op, register: register, offset: offset)
        case .jumpIfNotNil(let register, _):
            code.instructions[index] = .jumpIfNotNil(register: register, offset: offset)
        case .jumpIfNil(let register, _):
            code.instructions[index] = .jumpIfNil(register: register, offset: offset)
        case .jumpIfNotDeferred(let register, let bit, _):
            code.instructions[index] = .jumpIfNotDeferred(
                register: register,
                bit: bit,
                offset: offset
            )
        case .match(let pattern, let value, _):
            code.instructions[index] = .match(pattern: pattern, value: value, fail: offset)
        case .rangeNext(let counter, let variable, _):
            code.instructions[index] = .rangeNext(
                counter: counter,
                variable: variable,
                exit: offset
            )
        default: preconditionFailure("not a jump")
        }
    }

    mutating func jump(to target: Int) {
        let index = emit(.jump(offset: 0))
        patch(index, to: target)
    }

    mutating func allocate() throws -> Register {
        guard nextTemporary < Int(Register.max) - 1 else { throw Unsupported("too many registers") }
        defer { nextTemporary += 1 }
        highest = max(highest, nextTemporary)
        return Register(nextTemporary)
    }

    mutating func constant(_ value: Value) -> UInt32 {
        code.constants.append(value)
        return UInt32(code.constants.count - 1)
    }

    mutating func range(of program: Program, _ index: Int) -> Int32 {
        code.ranges.append(index < program.ranges.count ? program.ranges[index] : nil)
        return Int32(code.ranges.count - 1)
    }

    /// Where the errors of what is compiled next go, until `closeHandler`. It is made now and filled in
    /// later, so that an inner one is after the outer ones that contain it.
    mutating func openHandler(
        catches: Handler.Catches,
        register: Register? = nil,
        keepsError: Bool,
        isExpression: Bool = false
    ) -> Int {
        code.handlers.append(
            Handler(
                start: here,
                end: here,
                target: here,
                catches: catches,
                register: register,
                keepsError: keepsError,
                isExpression: isExpression
            )
        )
        return code.handlers.count - 1
    }

    /// The code the handler guards ends here.
    mutating func closeHandler(_ index: Int) { code.handlers[index].end = here }

    /// The handler's code begins here.
    mutating func aimHandler(_ index: Int) { code.handlers[index].target = here }

    func lookup(_ name: String) -> Local? {
        for scope in scopes.reversed() {
            if let local = scope.locals[name] { return local }
        }
        return nil
    }
}
