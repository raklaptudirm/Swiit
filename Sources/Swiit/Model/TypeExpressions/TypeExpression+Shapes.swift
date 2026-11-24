import Foundation

// What the checker and the evaluator ask of a type: the shapes Swift writes with sugar (`[T]`, `T?`,
// `[K: V]`), the names the module's own tables use, and a type's parts taken apart and put back.

extension TypeRef {
    /// Not known yet: what a program prints, or a builtin that has not declared its type. It fits
    /// anywhere, and anything fits it.
    static let unknown = TypeRef.native("_")
    /// A record whose fields are not known.
    static let record = TypeRef.native("Record")
}

extension TypeExpression {
    static let unknown = TypeExpression.named(.unknown)
    static let record = TypeExpression.named(.record)

    /// Swift's types that a script writes by name with an expression of its own: `Int`, `Void` (which
    /// is `()`), `Value` (which is `Any`), `Array<Int>` (which is `[Int]`). Nil for any other name, or
    /// for a name given the wrong number of arguments.
    static func spelled(_ name: String, _ arguments: [TypeExpression] = []) -> TypeExpression? {
        switch (name, arguments.count) {
        case ("Int", 0): .int
        case ("Double", 0): .double
        case ("String", 0): .string
        case ("Bool", 0): .bool
        case ("Record", 0): .record
        case ("Any", 0), ("Value", 0): .any
        case ("Void", 0): .void
        case ("Array", 1), ("Optional", 1), ("Dictionary", 2): .named(name, arguments)
        default: nil
        }
    }

    /// This type with each type it names by its text, as the checker and the evaluator write them:
    /// a declared type's reference is replaced by the name it was declared with.
    var byText: TypeExpression {
        if case .named(let named) = self {
            return .named(named.reference.name, named.arguments.map(\.byText))
        }
        return mapping { $0.byText }
    }

    /// What a parameter of `some Sequence<Element>` is: any sequence of them.
    static func someSequence(_ element: TypeExpression) -> TypeExpression {
        .named(.sequence, [element])
    }

    /// `KeyPath<Root, Value>`, what `\.size` is.
    static func keyPath(_ root: TypeExpression, _ value: TypeExpression) -> TypeExpression {
        .named(.keyPath, [root, value])
    }

    /// `Instance.Type`.
    static func metatype(_ instance: TypeExpression) -> TypeExpression {
        .metatype(Metatype(instance))
    }

    /// Whether this is `()`, which is what `Void` is.
    var isVoid: Bool {
        if case .tuple(let tuple) = self { tuple.elements.isEmpty } else { false }
    }

    /// The name of a type written as a bare name that the interpreter does not store itself: `Point`,
    /// `Set`, `Error`. Nil for `Int` and the other primitives, `Any`, a record, a function whose
    /// signature is not said, and a type not known yet.
    var plainName: String? {
        guard case .named(let named) = self, named.arguments.isEmpty, self != .any,
            self != .unknown, self != .record, self != .callable, !isPrimitive
        else { return nil }
        return named.reference.name
    }

    /// A named type with arguments that Swift does not write with sugar: `Set<Int>`, `Result<T, E>`.
    var genericParts: (name: String, arguments: [TypeExpression])? {
        guard case .named(let named) = self, !named.arguments.isEmpty,
            arrayElement == nil, optionalWrapped == nil, dictionaryTypes == nil,
            keyPathTypes == nil, sequenceElement == nil
        else { return nil }
        return (named.reference.name, named.arguments)
    }

    /// The Swift type's name and what it is generic over, for any named type: `Int`, `[String]` is
    /// `Array<String>`.
    var swiftType: (name: String, arguments: [TypeExpression])? {
        if case .named(let named) = self { (named.reference.name, named.arguments) } else { nil }
    }

    /// Whether this is written as a name that stands for a type of its own: `Int`, `[T]`, `Set<Int>`,
    /// `Point`. Not `T?`, `KeyPath<R, V>`, `some Sequence<E>`, `Any`, a record, a function whose
    /// signature is not said, or a type not known yet.
    var isNominal: Bool {
        guard case .named = self else { return false }
        return self != .any && self != .unknown && self != .record && self != .callable
            && optionalWrapped == nil && keyPathTypes == nil && sequenceElement == nil
    }

    /// Whether the interpreter stores its values itself: `Int`, `Double`, `String`, `Bool`.
    var isPrimitive: Bool {
        self == .int || self == .double || self == .string || self == .bool
    }

    /// `T` in `[T]`.
    var arrayElement: TypeExpression? {
        if case .named(let named) = self, named.reference == .array, named.arguments.count == 1 {
            named.arguments[0]
        } else {
            nil
        }
    }

    /// `T` in `T?`.
    var optionalWrapped: TypeExpression? {
        if case .named(let named) = self, named.reference == .optional, named.arguments.count == 1 {
            named.arguments[0]
        } else {
            nil
        }
    }

    /// `K` and `V` in `[K: V]`.
    var dictionaryTypes: (key: TypeExpression, value: TypeExpression)? {
        if case .named(let named) = self, named.reference == .dictionary,
            named.arguments.count == 2
        {
            (named.arguments[0], named.arguments[1])
        } else {
            nil
        }
    }

    /// `Root` and `Value` in `KeyPath<Root, Value>`.
    var keyPathTypes: (root: TypeExpression, value: TypeExpression)? {
        if case .named(let named) = self, named.reference == .keyPath, named.arguments.count == 2 {
            (named.arguments[0], named.arguments[1])
        } else {
            nil
        }
    }

    /// `E` in `some Sequence<E>`.
    var sequenceElement: TypeExpression? {
        if case .named(let named) = self, named.reference == .sequence, named.arguments.count == 1 {
            named.arguments[0]
        } else {
            nil
        }
    }

    /// This type with each type it is made of replaced by `transform`: a named type's arguments, a
    /// function's parameters, result and failure, a tuple's elements, a metatype's instance.
    func mapping(_ transform: (TypeExpression) -> TypeExpression) -> TypeExpression {
        switch self {
        case .named(let named):
            return .named(named.reference, named.arguments.map(transform))
        case .parameter:
            return self
        case .function(var function):
            function.parameters = function.parameters.map {
                FunctionType.Parameter(transform($0.type), isInout: $0.isInout)
            }
            function.returns = transform(function.returns)
            if case .typed(let failure) = function.throwing {
                function.throwing = .typed(transform(failure))
            }
            return .function(function)
        case .tuple(let tuple):
            return .tuple(
                Tuple(
                    tuple.elements.map { Tuple.Element(label: $0.label, type: transform($0.type)) }
                )
            )
        case .metatype(let metatype):
            return .metatype(Metatype(transform(metatype.instance)))
        }
    }
}
