import Foundation
import SwishKit

/// A mistake in types, found before anything runs: the statement (or, in a
/// script, the whole script) doesn't run. See Docs/Design/types.md.
@_spi(Shell) public struct TypeError: Error, CustomStringConvertible {
    @_spi(Shell) public let message: String
    /// The line of the statement it's in, when there's more than one.
    @_spi(Shell) public var line: Int?
    /// A call's arguments don't line up with a signature's parameters, as
    /// opposed to lining up with a value of the wrong type.
    @_spi(Shell) public var isArity = false

    @_spi(Shell) public init(_ message: String) {
        self.message = message
    }

    @_spi(Shell) public var description: String { message }
}

/// Works out the type of every expression and checks it fits where it's
/// used, as Swift does: local, two-way inference, with every function's
/// signature written. Names already bound in the shell (from earlier
/// entries at the prompt, and the builtins) come from the shell; those the
/// program declares come from the program.
///
/// It also decides what the interpreter would otherwise decide as it runs,
/// and writes that into the program it returns: which overload a call
/// uses (`.chosen`). Commands, pipelines and builtins' results are
/// `unknown` until phase 3, which fits anywhere.
@_spi(Shell) public final class TypeChecker {
    @_spi(Shell) public struct Signature {
        @_spi(Shell) public var name: String
        @_spi(Shell) public var parameters: [Parameter]
        @_spi(Shell) public var returns: TypeAnnotation
        @_spi(Shell) public var isMutating = false
        @_spi(Shell) public var isThrowing = false
        /// `rethrows`: a call throws if a closure passed to it does.
        @_spi(Shell) public var isRethrowing = false
        /// Its position among the overloads the interpreter will have.
        @_spi(Shell) public var index = 0
        /// Its type parameters and the protocols each must conform to:
        /// `sorted<V: Comparable>(by:)`, and a sequence method's `Element`.
        @_spi(Shell) public var generics: [String: [String]] = [:]
    
        @_spi(Shell) public init(name: String, parameters: [Parameter], returns: TypeAnnotation, isMutating: Bool = false, isThrowing: Bool = false, isRethrowing: Bool = false, index: Int = 0, generics: [String: [String]] = [:]) {
            self.name = name
            self.parameters = parameters
            self.returns = returns
            self.isMutating = isMutating
            self.isThrowing = isThrowing
            self.isRethrowing = isRethrowing
            self.index = index
            self.generics = generics
        }
    }

    @_spi(Shell) public struct StructInfo {
        @_spi(Shell) public var name: String
        @_spi(Shell) public var stored: [PropertyDecl]
        @_spi(Shell) public var computed: [String: TypeAnnotation]
        @_spi(Shell) public var methods: [String: [Signature]]
        @_spi(Shell) public var initializers: [Signature]
        @_spi(Shell) public var memberwise: Signature
        @_spi(Shell) public var conformances: [String] = []
        /// `static let` and `static var`, stored and computed: read on the type.
        @_spi(Shell) public var staticProperties: [PropertyDecl] = []
        @_spi(Shell) public var staticMethods: [String: [Signature]] = [:]

        @_spi(Shell) public func property(_ name: String) -> PropertyDecl? { stored.first { $0.name == name } }
        @_spi(Shell) public func staticProperty(_ name: String) -> PropertyDecl? { staticProperties.first { $0.name == name } }
    
        @_spi(Shell) public init(name: String, stored: [PropertyDecl], computed: [String: TypeAnnotation], methods: [String: [Signature]], initializers: [Signature], memberwise: Signature, conformances: [String] = [], staticProperties: [PropertyDecl] = [], staticMethods: [String: [Signature]] = [:]) {
            self.name = name
            self.stored = stored
            self.computed = computed
            self.methods = methods
            self.initializers = initializers
            self.memberwise = memberwise
            self.conformances = conformances
            self.staticProperties = staticProperties
            self.staticMethods = staticMethods
        }
    }

    @_spi(Shell) public struct EnumInfo {
        @_spi(Shell) public var name: String
        /// Each case's associated values, in declaration order.
        @_spi(Shell) public var cases: [(name: String, payload: [AssociatedValue])]
        @_spi(Shell) public var rawType: TypeAnnotation?
        @_spi(Shell) public var conformances: [String] = []

        @_spi(Shell) public func payload(of name: String) -> [AssociatedValue]? { cases.first { $0.name == name }?.payload }
    
        @_spi(Shell) public init(name: String, cases: [(name: String, payload: [AssociatedValue])], rawType: TypeAnnotation? = nil, conformances: [String] = []) {
            self.name = name
            self.cases = cases
            self.rawType = rawType
            self.conformances = conformances
        }
    }

    @_spi(Shell) public enum Symbol {
        case variable(TypeAnnotation, mutable: Bool)
        case functions([Signature])
        case structType(StructInfo)
        case enumType(EnumInfo)
        /// An imported module, `Tools`; its members aren't known until it loads.
        case module
        /// A Swift type by name, bridged: `String`, `Int`.
        case swiftType(String)
    }

    /// Where `return` goes: the declared result, or, for a closure that
    /// didn't say, the types its `return`s give.
    @_spi(Shell) public final class ReturnContext {
        @_spi(Shell) public let declared: TypeAnnotation?
        @_spi(Shell) public var seen: [TypeAnnotation] = []

        @_spi(Shell) public init(declared: TypeAnnotation?) {
            self.declared = declared
        }
    }

    /// Whether an error thrown here is handled: in a `throws` function, a
    /// closure, a `do` with a `catch`, or at the top level.
    @_spi(Shell) public struct ErrorContext {
        @_spi(Shell) public var handled: Bool
        /// What an error would have to leave, for messages.
        @_spi(Shell) public var boundary: Boundary = .topLevel

        @_spi(Shell) public enum Boundary {
            case topLevel, function(String), deferBlock

            /// Why an error can't get out, and what would let it.
            @_spi(Shell) public var unhandled: String {
                switch self {
                case .topLevel: "nothing catches it: use do/catch, try? or try!"
                case .function(let name): "\(name) isn't 'throws': mark it 'throws', or use do/catch, try? or try!"
                case .deferBlock: "nothing thrown can leave a defer: use do/catch, try? or try!"
                }
            }
        }
    
        @_spi(Shell) public init(handled: Bool, boundary: Boundary = .topLevel) {
            self.handled = handled
            self.boundary = boundary
        }
    }

    @_spi(Shell) public unowned let interpreter: Interpreter
    /// The type whose member was last looked up, so a JSON field can be
    /// written into a lookup that runs.
    @_spi(Shell) public var lastMemberBase: TypeAnnotation?

    /// What the program declares, innermost last, on top of the shell's names.
    @_spi(Shell) public var scopes: [[String: Symbol]] = [[:]]
    @_spi(Shell) public var returns: [ReturnContext] = []
    @_spi(Shell) public var errorContexts = [ErrorContext(handled: true)]
    /// Above zero while checking what a `try` covers.
    @_spi(Shell) public var tryDepth = 0
    /// Places that can throw, so far: how a `try` or a closure knows it
    /// covers one.
    @_spi(Shell) public var throwingSites = 0
    /// After an `import`, names it may bring can't be checked.
    @_spi(Shell) public var afterImport = false
    @_spi(Shell) public var line: Int?

    @_spi(Shell) public init(interpreter: Interpreter) {
        self.interpreter = interpreter
    }

    /// Checks a program, returning it with what was decided written in.
    @_spi(Shell) public func check(_ program: Program) throws(TypeError) -> Program {
        var checked = program
        do {
            try checkBlock(&checked)
        } catch var error as TypeError {
            error.line = error.line ?? line
            throw error
        } catch {
            preconditionFailure("the checker only throws TypeError")
        }
        return checked
    }

    /// The types of the globals a checked program declared, for the next
    /// entry at the prompt.
    @_spi(Shell) public var declaredGlobals: [String: TypeAnnotation] {
        scopes[0].compactMapValues { if case .variable(let type, _) = $0 { type } else { nil } }
    }

}

/// A host object the checker types without knowing its class: `Job`, an
/// imported module. Its members' types come from `Interpreter.objectMembers`.
@_spi(Shell) public protocol CheckedObject: SwishObject {
    var checkedType: TypeAnnotation { get }
    /// Whether a name bound to it is a module, whose members are looked up
    /// in the value.
    var isModule: Bool { get }
}

extension CheckedObject {
    @_spi(Shell) public var isModule: Bool { false }
}
