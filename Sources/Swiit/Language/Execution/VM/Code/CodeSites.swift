import Foundation

// What the instructions of a function's code name by an index and keep between runs: its call sites,
// the members, globals and patterns it reaches, the places it changes, and its closures, handlers and
// pieces left to the tree evaluator.

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
    /// For each parameter of `lastFunction`, the argument it takes, or -1 where its default is used; nil
    /// where the arguments do not fit it. It has a -1 only when `lastDefaults`.
    @exclusivity(unchecked) var lastMapping: [Int]?
    @exclusivity(unchecked) var lastDefaults = false
    /// What it called, and from which function when the scopes had this version: while neither has
    /// changed, the name need not be looked up again.
    @exclusivity(unchecked) var cached: Cached?

    /// The same, in what the loop reads without counting a reference: `cached` keeps them alive.
    @exclusivity(unchecked) var cachedCaller: ObjectIdentifier?
    @exclusivity(unchecked) var cachedVersion = -1
    @exclusivity(unchecked) var cachedCallee: Unmanaged<Function>?
    @exclusivity(unchecked) var cachedCode: Unmanaged<Code>?
    @exclusivity(unchecked) var cachedSharesScopes = false

    /// The struct type the name was found to be, when the names had this version and it was called from
    /// this function: what a call that makes a value need not look up again.
    @exclusivity(unchecked) var constructedType: StructType?
    @exclusivity(unchecked) var constructedVersion = -1
    @exclusivity(unchecked) var constructedCaller: ObjectIdentifier?
    /// The same for a class, with the one initializer it was found to run, and its code.
    @exclusivity(unchecked) var constructedClass: ClassType?
    @exclusivity(unchecked) var constructedInitializer: Function?
    /// The initializer of a struct found to take this call's labels, so that they are not compared
    /// again.
    @exclusivity(unchecked) var fittedInitializer: Function?
    /// The memberwise initializer of `constructedType` when it takes the labels of this site, and no
    /// extension adds initializers to the type.
    @exclusivity(unchecked) var memberwisePlan: MemberwisePlan?
    /// The function and initializer whose scopes the site compared, and whether they are the same.
    @exclusivity(unchecked) var sharesCaller: ObjectIdentifier?
    @exclusivity(unchecked) var sharesInitializer: ObjectIdentifier?
    @exclusivity(unchecked) var sharesScopes = false
    @exclusivity(unchecked) var constructedCode: Code?
    /// The plan of the native function the name was found to be, when the names had this version and
    /// it was called from this function; nil where it is not one a plan calls.
    @exclusivity(unchecked) var nativePlan: NativeFunctionPlan?
    @exclusivity(unchecked) var nativeVersion = -1
    @exclusivity(unchecked) var nativeCaller: ObjectIdentifier?

    struct Cached {
        let caller: Function
        let callee: Function
        let code: Code
    }

    /// Which of the overloads of the name the checker chose, when it did.
    let overload: Int?

    init(name: String?, callee: Expr, labels: [String?], overload: Int? = nil) {
        self.name = name
        self.callee = callee
        self.labels = labels
        self.overload = overload
    }
}

/// The members of Swift's `Array` and `String` that the loop makes itself.
enum FastMember: UInt8 {
    /// `xs.append(x)`, of a list whose elements are of the kind `x` is.
    case append
    /// `xs.count`
    case listCount
    /// `xs[i]` of an index within the list.
    case element
    /// `s.count`
    case stringCount
    /// `d[k]` of a dictionary: the value, or nil.
    case dictionaryElement
    /// `d.count`
    case dictionaryCount
    /// `xs.isEmpty`, `d.isEmpty`, `s.isEmpty`
    case isEmpty

    /// Whether the tree evaluator's call of the member takes a step: a property does, a subscript does not.
    var takesStep: Bool { self != .element && self != .dictionaryElement }

    /// What a member that only reads gives for `receiver` and `argument`, or nil where the kinds do not
    /// fit: then the tree evaluator reads it.
    static func read(_ kind: FastMember, _ receiver: Value, _ argument: Value) -> Value? {
        switch (kind, receiver.storage) {
        case (.listCount, .list(let items)): return .int(items.count)
        case (.element, .list(let items)):
            guard case .int(let index) = argument.storage, index >= 0, index < items.count else {
                return nil
            }
            return items[index]
        case (.stringCount, .string(let text)): return .int(text.count)
        case (.dictionaryElement, .dictionary(let dictionary)):
            return dictionary[argument] ?? .nothing
        case (.dictionaryCount, .dictionary(let dictionary)): return .int(dictionary.count)
        case (.isEmpty, .list(let items)): return .bool(items.isEmpty)
        case (.isEmpty, .dictionary(let dictionary)): return .bool(dictionary.isEmpty)
        case (.isEmpty, .string(let text)): return .bool(text.isEmpty)
        default: return nil
        }
    }
}

/// The pieces of an interpolated string: text, and which of the values made for it goes where.
final class StringSite {
    enum Piece {
        case text(String)
        case value(Int)
    }

    let pieces: [Piece]

    init(pieces: [Piece]) { self.pieces = pieces }
}

/// A member of a Swift type a body calls: which, and the labels of the arguments.
final class BridgedSite {
    let type: String
    let member: Int
    let labels: [String?]
    /// The member and the function made of it, found when the site first runs.
    @exclusivity(unchecked) var found: (member: BridgedMember, function: Function)?
    /// How the loop calls the member without binding a call's arguments, when it can: made when the site
    /// first runs.
    @exclusivity(unchecked) var plan: BridgedPlan?
    @exclusivity(unchecked) var isPlanned = false

    init(type: String, member: Int, labels: [String?]) {
        self.type = type
        self.member = member
        self.labels = labels
    }
}

/// A method a body calls on a local, and the one it was found to call when the names had this version.
final class MethodSite {
    let name: String
    let labels: [String?]
    @exclusivity(unchecked) var type: TypeRef?
    @exclusivity(unchecked) var classType: ObjectIdentifier?
    @exclusivity(unchecked) var version = -1
    @exclusivity(unchecked) var function: Function?
    @exclusivity(unchecked) var code: Code?
    /// The receiver is a variable that may be changed, so a method that changes it may be called.
    let mayMutate: Bool
    /// `super.name(…)`: the method is the one the class above the running method's has.
    let isSuper: Bool
    /// A computed property read: the method is the getter the type declares for the name.
    let isGetter: Bool
    /// The receiver is `self` of the running method, whose cell a struct that is changed goes back to.
    let receiverIsSelf: Bool
    /// The receiver is a global, whose cell a struct that is changed goes back to.
    let global: GlobalSite?
    /// For the method found, which argument each parameter takes (-1: its default), when some are left out.
    @exclusivity(unchecked) var mapping: [Int]?
    /// The function whose scopes the site compared with those of its method, and whether they are the
    /// same, so that a call leaves them as they are.
    @exclusivity(unchecked) var sharesCaller: ObjectIdentifier?
    @exclusivity(unchecked) var sharesScopes = false
    /// What the loop calls without leaving it, when the method found is one that undoes nothing as it
    /// returns (a struct's, that does not change `self`) and the site has the same caller, receiver type
    /// and names: not counted, as `function` and `code` are held while these are.
    @exclusivity(unchecked) var fastVersion = -1
    @exclusivity(unchecked) var fastCaller: ObjectIdentifier?
    @exclusivity(unchecked) var fastType: TypeRef?
    @exclusivity(unchecked) var fastClass: ObjectIdentifier?
    /// The method found changes its struct receiver, a local, which is moved into the cell of `self`
    /// while it runs and put back as it returns.
    @exclusivity(unchecked) var fastChangesReceiver = false

    /// Whether the global the receiver was loaded from, if it was, is still found in the cell the call
    /// puts a changed struct back in.
    @inline(__always)
    func globalFits(version: Int) -> Bool {
        guard let global else { return true }
        return global.version == version && global.function == fastCaller
            && (!fastChangesReceiver || (global.isMutable && global.cell != nil))
    }

    /// Whether the register holds a receiver of the kind the fast path found its method for.
    @inline(__always)
    func receiverFits(at register: UnsafeMutablePointer<Value>) -> Bool {
        VMStack.receiverFits(at: register, struct: fastType, instance: fastClass)
    }
    @exclusivity(unchecked) var fastFunction: Unmanaged<Function>?
    @exclusivity(unchecked) var fastCode: Unmanaged<Code>?

    init(
        name: String,
        labels: [String?],
        mayMutate: Bool,
        isSuper: Bool = false,
        isGetter: Bool = false,
        receiverIsSelf: Bool = false,
        global: GlobalSite? = nil
    ) {
        self.name = name
        self.labels = labels
        self.mayMutate = mayMutate
        self.isSuper = isSuper
        self.isGetter = isGetter
        self.receiverIsSelf = receiverIsSelf
        self.global = global
    }
}

/// A field of a struct a body sets through a local, and whether its type was found to let it be set
/// directly (no setter, no observer, a `var`) when the names had this version.
final class MemberSite {
    let name: String
    /// A struct it is set in may be changed: the local is a variable, or the method changes its receiver.
    let mutatesStruct: Bool
    /// It is set in an initializer: a field is made, and a `let` one may be, and no observer runs.
    let initializing: Bool
    /// The type its field is declared to have, when it was found to be set directly as it is made.
    @exclusivity(unchecked) var propertyType: TypeExpression? {
        didSet { propertyKind = propertyType.map(ParameterKind.init) ?? .any }
    }
    /// Which values `propertyType` plainly takes, without being conformed.
    @exclusivity(unchecked) var propertyKind = ParameterKind.any
    @exclusivity(unchecked) var type: TypeRef?
    @exclusivity(unchecked) var classType: ObjectIdentifier?
    @exclusivity(unchecked) var version = -1
    @exclusivity(unchecked) var isDirect = false

    init(name: String, mutatesStruct: Bool, initializing: Bool = false) {
        self.name = name
        self.mutatesStruct = mutatesStruct
        self.initializing = initializing
    }
}

/// A global variable a body names, and the cell it was found to be in last time.
final class GlobalSite {
    let name: String
    /// The cell, when the names had this version and the variable can be read and set through it.
    @exclusivity(unchecked) var cell: Binding.Cell?
    @exclusivity(unchecked) var version = -1
    @exclusivity(unchecked) var isMutable = false
    /// Which function's scopes it was found in: a body shared by closures is looked up for each.
    @exclusivity(unchecked) var function: ObjectIdentifier?

    init(name: String) { self.name = name }
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

/// The names a tuple pattern of names and wildcards binds: how many elements the tuple has, and the
/// register of each name with the position of the element it takes.
final class DestructureSite {
    let arity: Int
    let targets: [(position: Int, register: Register)]

    init(arity: Int, targets: [(position: Int, register: Register)]) {
        self.arity = arity
        self.targets = targets
    }
}

/// A place `assignPath` changes: the steps of its path, and what is done there.
final class PathSite {
    let steps: [Assignment.Step]
    let op: BinaryOperator?
    /// Every step is an index, so that the place is an element of lists in lists.
    let isIndexOnly: Bool

    init(steps: [Assignment.Step], op: BinaryOperator?) {
        self.steps = steps
        self.op = op
        isIndexOnly = steps.allSatisfy {
            if case .index = $0 { true } else { false }
        }
    }
}

/// A bridged member the loop calls with the values in the registers, in the order of its parameters:
/// each argument is looked at once and taken as it is where it is of the kind the parameter holds (and
/// conformed where not, as a call's binding does), and the glue is called with them as it takes them. A
/// member that changes its receiver, takes a variadic or a defaulted parameter, or is called with other
/// labels than its parameters', has no plan, and is called as a call is.
final class BridgedPlan {
    /// What a parameter of the member is given: the argument at a position of the call, or, for one the
    /// call leaves out, its default as a literal, or `.nothing`, which the member's Swift function fills
    /// in itself.
    enum Fill {
        case argument(Int)
        case value(Value)
    }

    /// How an argument of a parameter whose type is not a plain kind is seen to be of it without
    /// `conform`: the parameter's type is the host's, so it is never a class or a protocol the program
    /// declares, which `conform` looks the name up for. An argument that is not plainly of it is
    /// conformed as any is.
    enum HostCheck {
        /// A value of the Swift type of this name: boxed, or, for a Character, the one-letter String
        /// it is held as (the rules `conform` comes to after the names of the program's types).
        case named(String)
        /// Nothing short of `conform`.
        case general

        init(_ type: TypeExpression) {
            if type.genericParts == nil, let name = type.plainName {
                self = .named(name)
            } else {
                self = .general
            }
        }

        func accepts(_ value: Value) -> Bool {
            guard case .named(let name) = self else { return false }
            switch value.storage {
            case .object(let box as SwiftValue): return box.typeName == name
            case .string(let text): return name == "Character" && text.count == 1
            default: return false
            }
        }
    }

    let positional: @Sendable (Value, [Value]) throws -> Value
    /// For each parameter of the member, in order, what it is given.
    let fills: [Fill]
    /// For each parameter, how an argument is seen to be of its type where its kind does not say.
    let checks: [HostCheck]
    /// `Type.member`, which an error the member throws is said to come from.
    let place: String
    let function: Function
    let parameters: [Parameter]
    let kinds: [ParameterKind]
    let name: String
    /// `nil?.name` is nil, except for the members of `Optional` itself.
    let keepsNilReceiver: Bool

    init(
        positional: @escaping @Sendable (Value, [Value]) throws -> Value,
        function: Function,
        typeName: String,
        fills: [Fill]
    ) {
        self.positional = positional
        self.fills = fills
        place = "\(typeName).\(function.name ?? "member")"
        self.function = function
        parameters = function.parameters
        kinds = function.parameters.map { ParameterKind($0.type) }
        checks = function.parameters.map { HostCheck($0.type) }
        name = function.name ?? "member"
        keepsNilReceiver = typeName == "Optional"
    }
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

/// A closure as written, or a function declared in a block: what it captures from the code that makes
/// it.
final class ClosureSite {
    /// What the functions it makes are written as.
    enum Source {
        case literal(ClosureLiteral)
        /// A nested function, which is a closure with a name.
        case declaration(FunctionDecl)
    }

    let source: Source
    /// The locals it names, each kept in a cell the closure shares.
    let cells: [CapturedCell]
    /// The other names it uses, which are the enclosing closure's own captures, if anything.
    let others: [String]
    let captures: [TakenValue]
    /// What the VM made of the first function it made, which those made with as many scopes share:
    /// each is a new `Function`, and would be compiled again.
    @exclusivity(unchecked) var code = VMCode.untried

    init(
        source: Source,
        cells: [CapturedCell],
        others: [String],
        captures: [TakenValue]
    ) {
        self.source = source
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
    /// How many blocks that declare by name are open around it: an error it catches leaves the
    /// task's scopes at those the frame began with and theirs (`Code.scopeMark`).
    var scopeDepth = 0
}

/// How the loop calls a function written in Swift by name (`max(a, b)`): its body, and what each
/// parameter is given from the registers, as `bind` would give it.
final class NativeFunctionPlan {
    /// What a parameter is given: the argument at a position, its default, or, for a variadic one,
    /// the arguments from a position on, as a list.
    enum Fill {
        case argument(Int)
        case value(Value)
        case rest(Int)
    }

    let function: Function
    let body: @Sendable (Interpreter, _ receiver: Value, _ arguments: [Value]) throws -> Value
    let fills: [Fill]
    let kinds: [ParameterKind]
    let checks: [BridgedPlan.HostCheck]
    /// For each parameter, the kind of an element of its list, which a variadic one's arguments are.
    let elementKinds: [ParameterKind]

    init(
        function: Function,
        body:
            @escaping @Sendable (Interpreter, _ receiver: Value, _ arguments: [Value]) throws ->
            Value,
        fills: [Fill]
    ) {
        self.function = function
        self.body = body
        self.fills = fills
        kinds = function.parameters.map { ParameterKind($0.type) }
        checks = function.parameters.map { BridgedPlan.HostCheck($0.type) }
        elementKinds = function.parameters.map { ParameterKind($0.type.arrayElement ?? .unknown) }
    }
}
