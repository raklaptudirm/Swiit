
/// A library of functions and types written in Swift and bridged by
/// `swiit-bridge`, with the Swiit declarations a host adds to the prelude: the
/// core's own is `Library.standard`; a host has others (the shell's `ls` and
/// `ps` are `SwishShellLibrary`).
@_spi(Layer) public struct Library {
    /// Its structs and enums, as Swiit source, declared with the prelude.
    public var types: String
    public var functions: [BridgedMember]
    /// The Swift types it holds as they are and bridges the members of (`FileSize`), which the core's table does not have.
    public var bridged: [BridgedType]
    /// Swiit source a host writes by hand: structs, function signatures and
    /// `Sequence` extensions, read after the core prelude. Their bodies are in
    /// `bodies`.
    public var declarations: String
    /// Bodies for those declarations, by name (`help`, `Sequence.select`); a
    /// sequence method's also says how it reads the sequence.
    public var bodies: [String: (body: FunctionBody, input: Parameter?)]

    public init(
        types: String, functions: [BridgedMember],
        bridged: [BridgedType] = [], declarations: String = "", bodies: [String: (body: FunctionBody, input: Parameter?)] = [:]
    ) {
        self.types = types
        self.functions = functions
        self.bridged = bridged
        self.declarations = declarations
        self.bodies = bodies
    }

    /// The core's own: conversions (`from`, `to`, `table`, `list`) and styles.
    public nonisolated(unsafe) static let standard = Library( // safe: set once, before anything reads it
        types: Bridge.standardTypes, functions: Bridge.standardFunctions
    )
}
