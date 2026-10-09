# Boundaries

The embeddable core ([embedding.md](embedding.md)) is only as good as the line
between it and the shell. This note draws that line, says what may cross it
today and why, gives every crossing an exit, and describes the check that
keeps the line from moving the wrong way while the exits are built.

## The three boundaries

| Boundary | What it is | Mechanism |
|---|---|---|
| **Plumbing** | How an interpreter is run: output, errors, "should I stop", later module loading and limits | `SwishHost`, supplied by every embedder |
| **Vocabulary** | What a script can name: `env`, `jobs`, `history`, `ls`, an embedder's functions and types | Registration; a sandbox is the absence of a name |
| **Grammar** | What syntax the parser accepts and how it runs: commands, pipelines, `$(…)`, redirects | A layer the shell adds, which the desugaring turns into calls on the vocabulary |

## The rules

The files headed for the core are the ones in `Syntax`, `Checking`,
`Interpreter`, `Bridge`, `Display` and `Builtins` (50 files, 8,500 lines;
another 8 files, 1,760 lines, leave whole and are listed below). Since step 2 the
language layers are an `Interpreter` class and the shell owns one. For them:

1. **No direct reach into the operating system.** No descriptors, environment,
   signals, processes, terminal, directory, dynamic loading or threads; all of
   it goes through `SwishHost`. There is no allowance for this rule, and today
   nothing breaks it. (Step 5 of the embedding plan gives the interpreter a
   thread of its own for deep recursion; the rule is then amended for that
   one place.)
2. **No dependency on the shell's concepts** (commands and pipelines, `env`,
   jobs, exit statuses, the file being run, history, plugins, command
   resolution) **beyond the ledger.** Each line of the ledger is a
   transgression that has a named exit.
3. **A new file in those directories is checked from its first line,** with no
   allowance. Shell code goes in `Shell`, `Execution`, `Platform`, `Editor` or
   `Plugins`.

Not breaches: Foundation's value types (`Date`, `AttributedString`) and
swift-system's `FilePath`, which are values with no I/O.

## How it is kept

`BoundaryTests` reads the source and `Tests/SwishCoreTests/boundaries.txt`:

- A match of the operating-system pattern in any checked file fails the test.
- For each shell concept group, a file's count must equal the ledger's. More
  is a new dependency; fewer is an exit that wasn't recorded. Both fail, so the
  change that removes a transgression also lowers the ledger, and the ledger
  only shrinks.
- A ledger line for a file that has gone, or a leaving file that has moved,
  fails too.

The check is textual, comments excluded, and was tried against a deliberate
`getenv`, a new `Job` mention and a removed `scriptPath` before it was trusted.
It is a ratchet, not a proof: it can't see a dependency spelled in a way the
patterns don't know, so a new kind of shell concept means a new pattern.

## Files that leave whole

These are shell grammar or shell reflection inside core directories. They are
exempt from the check, pinned in the ledger, and move to `SwishShell` at step 4
of the embedding plan (or are deleted by the desugaring first).

| File | Lines | What it is | Exit |
|---|---|---|---|
| `Syntax/CommandNodes.swift` | 101 | Pipeline, command, redirect and stage nodes | Desugaring: nothing produces them |
| `Syntax/Parser+Commands.swift` | 255 | Parses command words, redirects, `VAR=x cmd` | The shell's parser layer |
| `Checking/TypeChecker+Pipelines.swift` | 389 | Types pipeline stages | Replaced by Swift's own resolution of the desugared calls |
| `Interpreter/Shell+CommandLine.swift` | 271 | Binds `--flag` words to a function's parameters | Becomes the shell's `Words` library |
| `Interpreter/ShellLayer.swift` | 43 | The internal ledger of what the core still asks the shell for | Empties as the groups below exit |
| `Bridge/Bridge+Stages.swift` | 138 | Bridged members as pipeline stages | With the pipeline checker |
| `Builtins/Shell+ShellBuiltins.swift` | 298 | `cd`, `exit`, `umask`, `which`, `run`… | The shell, as they are |
| `Builtins/Shell+Help.swift` | 267 | `help`: describes functions, builtins and programs | The shell for now; it names programs and shell builtins. Whether the reflection half is core is open (embedding.md) |

## The ledger: transgressors and their exits

101 uses across 43 file-and-group entries, eleven groups (it was 98 and nine
before step 2: two groups are new, the `shell` type and the `layer` slot, and
`file` has exited). Each exit names the plan step that carries it; "dynamic
members" is a step of the embedding plan (6), and "flatten" a step of the
desugaring (8).

| Group | What it is | Where | Exit |
|---|---|---|---|
| **grammar** (16) | `PipelineNode` in `Expr.command` and `.capture`, `Unit.pipeline`, redirects, and the passes that visit them | `Syntax` (4 files), `TypeChecker+Declarations`, `+Statements`, `Interpreter+Environment`, `+Statements` | Desugaring steps 3 to 7 remove every producer; embedding step 3's Swift-only parse mode rejects the nodes; then they are deleted, or move with the shell's parser. Until then each use is a case that asks the layer. |
| **chain** (20) | `Statement.chain(Chain)` wraps every expression statement as `&&`/`||`-joined units with an exit status, because a statement was a command first | `Syntax` (3 files), `TypeChecker` (3 files), `Interpreter+Statements` | Desugaring step 8, "flatten": command chains become library calls, `Unit`'s cases hoist into `Statement`, `Chain` is deleted. A Swift-only core has statements that are expressions, `if`, `for`, `while` and `switch`. |
| **env** (20) | `env` is special everywhere: a scope binding kind, `Statement.setEnvironment`, `$NAME`, and a checker symbol with its own member types | `Interpreter+Expressions` (7), `Interpreter+Environment` (4), `Interpreter+Statements`, `TypeChecker` (3 files), `Interpreter+Builtins` | Embedding step 6, host objects with dynamic members: a `SwishObject` can assign members and say their types, and `env` is registered as one. The special binding, statement and symbol go; `$NAME` is the desugarer's `Environment["NAME"]`. The same feature serves JSON as a real type (foundations.md) and an embedder's own objects. |
| **jobs** (13) | `Job` named in the checker and `await`'s operand type, `Job.members` read by name, a `jobs` scope binding | `TypeChecker` (3 files), `Interpreter+Expressions`, `Scope`, `Interpreter+Builtins` | Async plan steps 5 and 6 with dynamic members: `Job` becomes an ordinary registered type that declares its members and its `Tabular` columns itself, `jobs` a registered global, `await` typed by a handle protocol. (`Display` stopped naming `Job` at step 2: the shell lends its tables' columns through the layer.) |
| **layer** (16) | Uses of the `shellLayer` slot and its accessors: the core asking the shell for the environment, commands, jobs, `await`, sequence methods, columns. The slot's own declaration in `Interpreter` is 4 of them | `Interpreter+Expressions` (9), `Interpreter` (4), `Interpreter+Environment`, `+Statements`, `Display` | The slot goes last, when its entries have: each use is one of the other groups' exits. |
| **shell** (2) | The checker holds the `Shell`, so the pipeline checker (a shell file extending the checker) can ask it what a name is | `TypeChecker` | With the pipeline checker, which the desugaring replaces by Swift's own resolution. |
| **status** (6) | Every statement returns an exit status, `lastStatus` stores it, `exitCode` maps it to a signal | `Interpreter+Statements` (3), `Interpreter` (2, the fields), `Interpreter+Environment` | After flatten, statements return nothing; the shell records the status of command statements per task (async.md, task context); `exitCode` moves with the shell half of `Interpreter+Environment`. |
| **history** (1) | The `ShellContext` lent to library functions carries `history` | `Bridge+Conversions` | Embedding step 4: `ShellContext` splits. The core lends output and display facts; `history(in:)` moves to the shell's library, which asks the shell. |
| **plugin** (6) | `import Name from path` loads a dylib: a statement, the parser, the checker, the interpreter | `Syntax` (2), `TypeChecker+Statements`, `Interpreter+Statements` | Embedding steps 5 and 7: `import Name` is resolved by the host (`loadModule`); the dylib loader is the shell's implementation of it, and the `from path` form is shell syntax. |
| **commands** (1) | `commandFunctions(named:)`, the lookup of functions callable as command words | `Interpreter+Scopes` | Leaves with grammar at step 4. |
| ~~**file**~~ | The `.filePath` expression read the shell's `scriptPath` | | **Exited at embedding step 2:** the file being run is the interpreter's own state (`Interpreter.file`), set by whoever runs a file. |

### Known leaks the patterns don't see

The check finds names, so it can't see these. They are recorded here so they
are not forgotten:

- **The shell's library functions are installed by the core.**
  `installStandardFunctions` registers everything in `Bridge.standardFunctions`,
  which includes `ls`, `ps`, `pwd`, `readLine` and `history`. Exit: embedding
  step 4 splits `SwishStandardLibrary` into the pure part and the shell's, and
  the shell registers its own.
- **The prelude declares the shell's `help`.** `Prelude.swift` declares
  `help` and the `Help` struct, and the shell supplies the body. Exit: the
  prelude splits at step 4, with `help` in the shell's half.
- **`Interpreter.init` takes no builtins.** An embedder has to call
  `installBuiltinFunctions`; step 5's public initializer does it.

### Files that stay but must split

Four checked files hold both halves and are split at step 4 of the embedding
plan, when their shell half moves:

- `Interpreter/Interpreter+Environment.swift`: string interpolation (`expand`)
  is core; `environmentRecord`, `exitCode`, `withEnvironment`, redirect
  resolution and word expansion are the shell's.
- `Interpreter/Interpreter+Expressions.swift` and `+Statements.swift`: the
  evaluator is core; the shell cases in them (env, layer, pipelines, chains,
  statuses) go as their groups exit, which is why they carry the most
  allowances.
- `Builtins/Interpreter+Builtins.swift`: installing the prelude's functions,
  the JSON access helpers and `declaredCase` are core; the `env` and `jobs`
  bindings are not.

## The order the exits come in

1. **Embedding step 2** (language state into `Interpreter`): `file`. *Done.*
2. **Embedding step 4** (split the targets): `history`, `commands`, the mixed
   files, and the files that leave whole.
3. **Embedding step 6** (dynamic members), then **async steps 5 and 6**: `env`,
   then the type half of `jobs`.
4. **Desugaring steps 3 to 7**, with **embedding step 3** (Swift-only parse
   mode): `grammar`, and the `commandAccess` uses of `jobs`.
5. **Desugaring step 8** (flatten): `chain`, then `status`.
6. **Embedding steps 5 and 7**: `plugin`.

The core is done when the ledger is empty and `ShellLayer` is deleted. Steps
2 and 4 are fixed by the embedding plan's order; the rest are ordered by what
needs what, and can be taken in whichever order work reaches them.
