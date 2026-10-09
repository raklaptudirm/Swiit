import SwishKit

/// A library of functions and types written in Swift and bridged by
/// `swiit-bridge`, with the Swish declarations a host adds to the prelude: the
/// core's own is `Library.standard`; a host has others (the shell's `ls` and
/// `ps` are `SwishShellLibrary`).
@_spi(Shell) public struct Library {
    /// Its structs and enums, as Swish source, declared with the prelude.
    @_spi(Shell) public var types: String
    /// The columns a table starts with, for its types that say so.
    @_spi(Shell) public var columns: [String: [DisplayColumn]]
    /// How its enums' cases are styled, by case name.
    @_spi(Shell) public var enumStyles: [String: @Sendable (String) -> DisplayStyle?]
    @_spi(Shell) public var functions: [BridgedMember]
    /// Swish source a host writes by hand: structs, function signatures and
    /// `Sequence` extensions, read after the core prelude. Their bodies are in
    /// `bodies`.
    @_spi(Shell) public var declarations: String
    /// Bodies for those declarations, by name (`help`, `Sequence.select`); a
    /// sequence method's also says how it reads the sequence.
    @_spi(Shell) public var bodies: [String: (body: FunctionBody, input: Parameter?)]

    @_spi(Shell) public init(
        types: String, columns: [String: [DisplayColumn]],
        enumStyles: [String: @Sendable (String) -> DisplayStyle?], functions: [BridgedMember],
        declarations: String = "", bodies: [String: (body: FunctionBody, input: Parameter?)] = [:]
    ) {
        self.types = types
        self.columns = columns
        self.enumStyles = enumStyles
        self.functions = functions
        self.declarations = declarations
        self.bodies = bodies
    }

    /// The core's own: conversions (`from`, `to`, `table`, `list`) and styles.
    @_spi(Shell) public nonisolated(unsafe) static let standard = Library(
        types: Bridge.standardTypes, columns: Bridge.standardColumns,
        enumStyles: Bridge.standardEnumStyles, functions: Bridge.standardFunctions
    )
}
