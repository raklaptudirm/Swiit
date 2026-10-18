import Foundation
/// What the shell lends a function that asks for it. A parameter of this type
/// is filled in when the function is called and is never a command-line
/// argument or a flag: `func history(in shell: HostContext) -> [String]`.
public struct HostContext: Sendable {
    /// What was entered at the prompt, oldest first.
    public let history: [String]
    /// Whether output to the terminal may be colored.
    public let colorOutput: Bool

    /// What else the host lends, by name, for a library's functions to read through a typed property of their own
    /// (the shell's `display`: how its types show in a table).
    public var extras: [String: any Sendable]

    public init(history: [String], colorOutput: Bool, extras: [String: any Sendable] = [:]) {
        self.history = history
        self.colorOutput = colorOutput
        self.extras = extras
    }
}
