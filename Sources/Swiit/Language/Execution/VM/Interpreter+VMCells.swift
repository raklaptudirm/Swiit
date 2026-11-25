import Foundation

// safe: a cell is read and changed only holding the interpreter lock, as every variable is
/// A variable a closure captures is held in the register of the frame that declared it as the cell
/// itself, which the closure's scope has a binding of too, so the two see each other's changes. So is the
/// cell of `self` in a method.
extension Binding.Cell: LanguageObject, @unchecked Sendable {
    var typeName: String { "Variable" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { value.description }
    var debugDescription: String { value.debugDescription }
}
