import SwishKit

/// The shell's constructs the core still calls: the sequence methods.
/// (Running pipelines and `$(…)` are the shell's own nodes, which reach their
/// `Shell` through `Interpreter.owner`.)
@_spi(Shell) public struct CommandAccess {
    /// `xs.select(…)`: a sequence method called on a list, whose `@input`
    /// the pipeline machinery feeds.
    @_spi(Shell) public var callSequenceMethod: (OverloadSet, _ items: [Value], [Argument]) throws -> Value

    @_spi(Shell) public init(callSequenceMethod: @escaping (OverloadSet, _ items: [Value], [Argument]) throws -> Value) {
        self.callSequenceMethod = callSequenceMethod
    }
}

/// What the core still can't do without the shell. It is not part of the
/// host an embedder supplies: it is internal and temporary, a ledger of the
/// places the language layers depend on shell concepts, each with its exit
/// (Docs/Design/embedding.md). Without a layer, the core refuses them
/// plainly: `env` reads as empty and can't be set, commands and jobs don't run.
///
/// | Entry | Belongs to | Exit |
/// |---|---|---|
/// | `commands.callSequenceMethod` | grammar | the desugaring |
@_spi(Shell) public struct ShellLayer {
    @_spi(Shell) public var commands: CommandAccess
    /// Loads a plugin: `import Name from path`.
    @_spi(Shell) public var importPlugin: (_ name: String, _ path: String) throws -> Void
    /// What was entered before, oldest first.
    @_spi(Shell) public var history: () -> [String]

    @_spi(Shell) public init(commands: CommandAccess, importPlugin: @escaping (_ name: String, _ path: String) throws -> Void, history: @escaping () -> [String]) {
        self.commands = commands
        self.importPlugin = importPlugin
        self.history = history
    }
}

extension Interpreter {
    /// Commands, jobs and `$(…)`, or a refusal where there is no shell layer.
    @_spi(Shell) public func commandAccess() throws -> CommandAccess {
        guard let layer = shellLayer else { throw RuntimeError("commands aren't available here") }
        return layer.commands
    }

    /// `import Name from path`, or a refusal where there is no shell layer.
    @_spi(Shell) public func importPlugin(_ name: String, from path: String) throws {
        guard let layer = shellLayer else { throw RuntimeError("plugins can't be imported here") }
        try layer.importPlugin(name, path)
    }

    /// What was entered before, for the library functions that ask.
    @_spi(Shell) public var historyEntries: [String] { shellLayer?.history() ?? [] }
}
