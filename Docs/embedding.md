# Embedding

Swish's interpreter should be usable as a library: an app or a tool links it,
hands it Swift functions and values, and runs scripts written in Swift, with
no shell, no terminal and no process access unless the host grants it. This
is the design for separating that core out. It follows
[direction.md](direction.md) (Swish is a Swift interpreter first, with the
shell as seasoning) and is the first thing to build, ahead of
[desugaring.md](desugaring.md) and [async.md](async.md), which both build on
the seam it creates.

Step 1 of the plan is built (the `SwishHost` seam); the rest is not. This
records what is decided, the shape, and an order. The line between the core and
the shell, what may cross it today and how each crossing exits are in
[boundaries.md](boundaries.md), and a test enforces them.

## Where it stands

About two thirds of `SwishCore` (9,100 of 13,800 lines) is the language:
`Syntax`, `Checking`, `Interpreter` and `Bridge`. It almost never touches the
operating system. What stops it being a library:

- **`Shell` is the interpreter.** The evaluator is eleven `extension Shell`
  blocks, and `TypeChecker` is built with `shell:` and reads 13 different
  members of it. The class holds language state (`scopes`, `sequenceMethods`,
  `staticTypes`, the enum tables, `returnTypes`, `callDepth`) next to process
  state (`stdoutFD`, the terminal, `termios`, `jobs`, the line editor,
  history, `scriptPath`, plugins).
- **No way in or out.** The public surface is `execute(_:) -> Int32`,
  `runScript` and `runInteractive`. A value can't be returned, a global can't
  be set, a function can't be registered. Errors are printed to stderr and
  output is written to file descriptors.
- **Process-wide assumptions.** Recursion needs the 1 GB-stack thread that
  `main.swift` makes (there is a `maxCallDepth`, but the stack has to hold
  it). Interrupts are one global signal flag. `Shell.init` ignores SIGPIPE.
  `Bridge.types` is a static table built from four generated lists, and the
  generator's module table is hardcoded, so a host can't add types.
- **The standard library mixes pure and OS code.** `Flow`, `JSON`, the
  formatter, the pretty printer, `from`, `to`, `table` and `list` are pure.
  `ls`, `ps`, `pwd`, `readLine`, `history`, `with(env:)`, jobs and paths are
  the shell's. The bridged Swift standard library, `FilePath` and `Date` are
  values with no I/O, so a core with no ambient authority is possible.
- **Shell syntax lives in the parser and the tree:** `CommandNodes`,
  `Parser+Commands`, pipeline units. About 2,000 lines of command machinery
  sit in or beside the language layers.

Two things already help. SwishKit is a host ABI (`Value`, `SwiftValue`,
`SwishObject`, `Partial`, `ShellContext`, `@SwishExport`), so host values
and functions have a vocabulary. And the desugaring plan turns shell
constructs into library calls, so the core doesn't need to understand them.

## Decided

- **`SwishCore` becomes the embeddable core,** and the shell moves to a new
  `SwishShell` target that depends on it. The `swish` executable depends on
  `SwishShell`.
- **The core is Swift only.** Shell syntax belongs to the shell. Until the
  desugaring exists the core keeps the shell nodes in its tree, but a
  Swift-only parse mode rejects them, and evaluating one asks the host, which
  the sandbox refuses.
- **Host functions are registered at run time first:** typed closures, no
  build step. `@SwishExport` covers types next; pointing the generator at a
  host module follows once its module table is configurable.
- **The split comes before desugaring and async.** The `SwishHost` seam is where
  async's per-task context and `suspend` function go, and where the
  desugaring library lives.

## The shape

| Target | Contents |
|---|---|
| `SwishKit` (exists) | `Value`, boxing, `SwishObject`, `@SwishExport`: what a host and a plugin share with the interpreter |
| `SwishCore` | Syntax, checking, the interpreter, the bridge runtime and its generated glue for Swift, swift-system, SwishKit and Foundation, `SwishHost`, the embedding API |
| `SwishStandardLibrary` | The pure part: `Flow`, `JSON`, formatter, pretty printer, `Sequence` extensions, `from`/`to`/`table`/`list`, text styling |
| `SwishShellLibrary` (new) | The OS functions: `ls`, `ps`, `pwd`, `readLine`, `history`, `with(env:)`, jobs, paths, input |
| `SwishShell` (new) | `Shell`, execution, platform, the line editor, shell builtins, config, plugin loading, tasks |
| `Swish` (exists) | The `swish` executable |

### `SwishHost`: the seam and the sandbox

The interpreter reaches the world through one value, a `SwishHost`. It is named
like SwishKit's public types (`SwishObject`, `SwishError`), and not `Host`,
because Foundation already has a `Host` (`NSHost`) that an embedder importing
both would trip over.

It is a small struct of callbacks and optional capabilities, not a protocol
with a method per feature. That is how other embeddable languages are
configured: Wren's configuration is a struct of optional callbacks (`writeFn`,
`errorFn`, `loadModuleFn`, an allocator, heap settings); Rhai has `on_print`,
`on_debug` and `on_progress` hooks, `set_max_*` limits, `new_raw` for an engine
with no standard library, and `register_fn` and `set_module_resolver` for the
rest; Starlark has `Thread.Cancel` and `SetMaxExecutionSteps` and takes its
globals as `predeclared`. (Lua, the JavaScript engines and Java's JSR-223 do
the same from what I know of them; I did not check those against their
documentation.) The pattern: a few callbacks for what crosses every script
(output, errors, loading a module, "should I stop"), limits as plain data, and
everything else is a capability the host registers, so a sandbox is the absence
of a global, not a method implemented as a no-op.

```swift
struct SwishHost {
    var output: OutputSink          // write, plus what the stream can show (terminal? width? styled?)
    var error: OutputSink
    var interrupt: () -> StopReason?  // asked at each step: a reason to stop, if there is one
}
```

That is all of it, because it is only one of three boundaries, and each has
its own mechanism:

| Boundary | What it is | Mechanism |
|---|---|---|
| Plumbing | How this interpreter is run: output, errors, "should I stop", later module loading and limits | `SwishHost`; every embedder supplies it |
| Vocabulary | What a script can name: `env`, `jobs`, `history`, `ls`, `Command`, an embedder's functions and types | Registration; a sandbox is the absence of a name |
| Grammar | What syntax the parser accepts and how it runs: commands, pipelines, `$(…)`, redirects | A layer the shell adds, which the desugaring turns into calls on the vocabulary |

Defaults do nothing: output is discarded, nothing asks to stop. `StopReason`
is opaque to the interpreter, which only carries it in the `Interrupted` error
so whoever asked can read it back (the shell's is the signal number, so it can
end by that signal); the core has no idea what a signal is.

**What the core still can't do without the shell** is not on the host. It is an
internal, temporary `ShellLayer` the interpreter holds optionally, which an
embedder never sees or implements. Without one, `env` reads as empty and can't
be set, and commands, `$(…)` and jobs are refused with a plain error. Each
entry is a leak with a named exit:

| Entry | Belongs to | Exit |
|---|---|---|
| `environment` | vocabulary | `env` as a registered object with dynamic members: member assignment on host objects, and a way for an object to say its members' types. The JSON open question in `foundations.md` wants the same feature, so it is built once for both. |
| `jobs` | vocabulary | A registered global |
| `commands.run`, `start`, `capture` | grammar | The desugaring: the core never sees those nodes |
| `commands.hasProgram` | grammar | The shell's own name resolution |

Not on either: the file being run is interpreter state (set by whoever runs
a file), and history is the shell's `history` function. Still to add to the
host for embedders: `loadModule` (a script importing another) and limits
(steps, depth, time, output size) as data beside it.

### The embedding API

```swift
let swish = Interpreter(host: SwishHost(output: .init { print($0, terminator: ""); return true }),
                        limits: .init(steps: 1_000_000, depth: 200, time: .seconds(2)))
swish.register("clamp") { (x: Int, lo: Int, hi: Int) in min(max(x, lo), hi) }
swish.set("config", config)                         // any Encodable, or a Value
let level = try swish.eval("clamp(config.volume * 2, 0, 100)")   // a Value
let n: Int = try level.as(Int.self)
```

- **Errors are values.** `eval` throws a `Diagnostic` with kind (syntax, type,
  runtime), message, file and line. Column is added when the parser tracks it.
- **Registered functions** are typed by Swift generics: parameters convert
  through SwishKit's existing rules, and a script sees a normal Swish function
  with the labels given. A wrong argument is the usual type error.
- **`eval` is blocking and runs on an internal large-stack thread,** so the
  embedder needs no stack setup. An `Interpreter` is used from one thread at a
  time; the async plan changes how waiting works later.
- **Instances are isolated.** Globals, registered functions, types and limits
  belong to the instance. The standard bridge tables stay shared and
  immutable; host additions layer over them per instance.
- **Limits are steps, depth, time and output size.** A step is a statement or
  a call. A hit limit is a runtime `Diagnostic`, not a crash. Memory is not
  limited: a script that builds a huge list can only be bounded by steps and
  time, and that is said plainly in the documentation.

## What moves

| From `SwishCore` | Goes to |
|---|---|
| `Syntax`, `Checking`, `Interpreter`, `Bridge`, generated glue | stays; loses its `Shell` and POSIX references |
| `Shell/Shell.swift` (class) | split: language state to `Interpreter` (core), process state stays in `Shell` |
| `Shell/` scripts, tasks, interactive, config | `SwishShell` |
| `Execution/`, `Platform/`, `Editor/`, `Plugins/` | `SwishShell` |
| `Builtins/` | shell builtins (`cd`, `exit`, `run`…) to `SwishShell`; the prelude and sequence methods stay |
| `Display/Display.swift` | the sink-based `show` stays; the fd-based formatter constructors go to `SwishShell` |
| `SwishStandardLibrary` OS functions | `SwishShellLibrary` |

Open placement: `help`, `members` and `which` describe the language's own
scopes and types, so they arguably belong to the core, but their output is
terminal-styled. They stay with the shell for now.

## Plan

Each step is its own change, ends with all 267 tests passing, and leaves the
shell working.

1. **The `SwishHost` seam, no moves.** *Done.* `SwishHost`
   (`Interpreter/SwishHost.swift`) and the internal `ShellLayer`
   (`Interpreter/ShellLayer.swift`) are defined, and the shell fills both with
   the process (`Shell/SwishHost+Process.swift`), reached as `shell.host` and
   `shell.shellLayer`. Everything in the language layers that writes output,
   checks for interrupts, reads or sets the environment, captures output, runs
   a pipeline, starts or lists jobs, or asks whether a program exists goes
   through one of them, and a grep of `Syntax`, `Checking`, `Interpreter` and
   `Bridge` finds no direct output descriptor, environment or signal call.
   Behavior is unchanged: the original 267 tests and the interactive scripts
   pass, and `HostTests` swaps in a recording host and layer, and a shell with
   no layer, to prove it. It went through two shapes first: a thirteen-method
   protocol, then a struct that also held the environment and commands; both
   were pared down after comparing how other embeddable languages are
   configured, and on the principle that plumbing, vocabulary and grammar are
   separate boundaries (above). Other differences from what this document first
   planned: the types are internal until step 5, since `ShellLayer` still names
   the shell's `PipelineNode`; the fd-based formatter constructors,
   `terminalWidth` and `Shell+Capturing` moved beside the shell's code; and
   there is no clock, file or line-input capability, because nothing in the
   language layers asks for one.
2. **Language state out of `Shell`.** An `Interpreter` class holds `scopes`,
   `sequenceMethods`, `staticTypes`, the enum tables, `returnTypes`,
   `callDepth` and the host; `Shell` owns one. The `extension Shell` blocks in
   `Interpreter/` become extensions of it, `TypeChecker` takes it, and the
   existing `enum Interpreter` namespace is renamed. The generated glue's
   `shell` parameter becomes the interpreter, which means regenerating the
   bridge (with the bootstrap workaround).
3. **Swift-only parse mode,** with shell nodes evaluated through the host.
   The sandbox host refuses them.
4. **Split the targets.** `SwishShell` and `SwishShellLibrary` created, files
   moved, `SwishStandardLibrary` and the generator's module table split, the
   tests divided into core and shell, CI updated. The core builds with no
   reference to the shell.
5. **The embedding API:** the public `Interpreter`, `SwishHost`, `Diagnostic`,
   `register`, `set`, `eval`, output sink, limits and cancellation, the
   internal large-stack thread.
6. **Host objects with dynamic members:** a `SwishObject` can assign its
   members and say their types, so a host registers an object whose members are
   computed (`env`, `jobs`, JSON) and the checker types them. This retires the
   `env` special cases ([boundaries.md](boundaries.md)) and is the feature the
   JSON open question in `foundations.md` waits on.
7. **Host types:** per-instance registry layered over the standard one, so a
   host can register a type, not only functions; `@SwishExport` usable in
   process.
8. **Documentation, an example package, and a CI check** that the core target
   builds without the shell. (The check that no core file reaches the operating
   system exists from step 1: `BoundaryTests`.)

Tests that must hold by the end: `eval` returns values and structured
errors; the sandbox refuses commands, files and environment with clear
messages; an infinite loop and a deep recursion stop cleanly at their limits;
two interpreters in one process don't see each other's globals or registered
functions; a registered closure's argument errors read like any function's;
output goes to the sink; the core builds on Linux with no shell target.

## Risks

- **Step 2 is wide.** It touches thousands of lines, though mechanically
  (`extension Shell` to `extension Interpreter`). It is done in small commits
  by scripted renames, with the test suite after each.
- **Generated code names the shell.** Native bodies take `shell` and use
  `shell.context`, `shell.declaredCase`, `shell.reportItemError`. Renaming
  regenerates all bridges, which hits the bootstrap deadlock; the workaround
  is known.
- **`ShellContext` in SwishKit** is named for the shell and lent to library
  functions. It becomes the host's context. It's pre-v1, so renaming it is
  allowed, and the plugin ABI number isn't bumped.
- **Stack depth.** An internal thread solves it for `eval`, but a registered
  closure that calls back into the interpreter recurses on whatever thread it
  runs on. The depth limit has to be set with that in mind.
- **Foundation.** `Date` and `AttributedString` are bridged. Linux works
  today; WASM would need `FoundationEssentials`, which is untested.

## Open questions

- **How does a script load another?** `source` and `import X from path` are
  shell and plugin features. An embedded language usually wants
  `import "helpers"` resolved by the host (`host.resolveImport(name) -> source`).
- **Where do `help`, `members` and `which` live,** given what they describe?
- **Is the `Value` API enough,** or should hosts decode a `Value` into a
  `Decodable` type? `ValueEncoder` goes the other way already.
- **Targets beyond macOS and Linux:** iOS is the same code; WASM needs a
  look at Foundation and at threads.
- **Naming the embedding product.** A package that consumers depend on may
  want a friendlier library name than `SwishCore`. (The seam protocol is
  settled: `SwishHost`.)
