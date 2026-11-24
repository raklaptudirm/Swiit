import Foundation

// safe: a cell is read and changed only holding the interpreter lock, as every variable is
/// A variable a closure captures, held in the register of the frame that declared it. The closure's
/// scope has a binding of the same cell, so the two see each other's changes.
final class CellBox: LanguageObject, @unchecked Sendable {
    let cell: Binding.Cell

    init(_ value: Value) { cell = Binding.Cell(value) }

    var typeName: String { "Variable" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { cell.value.description }
}
