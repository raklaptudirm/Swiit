import Foundation
import SwiftSyntax
import Synchronization

// Looking up what a type is and has, from the types themselves.

extension TypeRef {
    /// The reference of the type a script can name `name`: one it or the host declares, or one of Swift's
    /// the core bridges. Nil when there is none. A host asks once, after loading the source that
    /// declares the type, and keeps the answer.
    public init?(named name: String, in interpreter: Interpreter) {
        guard let found = interpreter.typeRef(named: name) else { return nil }
        self = found
    }

    /// The symbol this reference names: a script's declaration (even one that a later declaration of the
    /// same name hides), or a type the host registers or the core bridges. It returns nil for a reference
    /// that names nothing: an unregistered Swift type (such as an encoded value's) or a declared type of
    /// another interpreter.
    public func symbol(in interpreter: Interpreter) -> Symbol.Nominal? {
        interpreter.symbol(for: self)
    }
}

extension TypeExpression {
    /// The members of the type: the methods and properties of its values (a struct's, a host object's, a
    /// bridged type's, the sequence methods of a list), and what belongs to the type itself, marked
    /// `isStatic`: its static members, its initializers and an enum's cases. With `name`, only those so
    /// called. `TypeExpression(Int.self).members(in: interpreter)` lists what a Swift type has for scripts.
    public func members(named name: String? = nil, in interpreter: Interpreter) -> [Symbol] {
        interpreter.members(of: self, named: name)
    }
}

extension Sequence where Element: CallableSymbol {
    /// Which of these functions a call with these arguments means: by their labels and types, the
    /// one that fits with the fewest conversions. Throws the checker's own complaint when none fits
    /// or several do.
    public func overload(
        arguments: [TypeExpression.TupleElement],
        in interpreter: Interpreter
    ) throws(Diagnostic) -> Element {
        try interpreter.overload(among: Array(self), arguments: arguments)
    }
}
