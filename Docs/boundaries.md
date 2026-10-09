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
another 8 files, 1,760 lines, leave whole and are listed below). For them:

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

98 uses across 39 file-and-group entries, nine groups. Each exit names the plan
step that carries it; "dynamic members" is a new step in the embedding plan
(step 6), and "flatten" a new step in the desugaring (step 8).

| Group | What it is | Where | Exit |
|---|---|---|---|
| **grammar** (16) | `PipelineNode` in `Expr.command` and `.capture`, `Unit.pipeline`, redirects, and the passes that visit them | `Syntax` (4 files), `TypeChecker+Declarations`, `+Statements`, `Shell+Environment`, `Shell+Statements` | Desugaring steps 3 to 7 remove every producer; embedding step 3's Swift-only parse mode rejects the nodes; then they are deleted, or move with the shell's parser. Until then each use is a case that asks the `ShellLayer`. |
| **chain** (20) | `Statement.chain(Chain)` wraps every expression statement as `&&`/`||`-joined units with an exit status, because a statement was a command first | `Syntax` (3 files), `TypeChecker` (3 files), `Shell+Statements` | Desugaring step 8, "flatten": command chains become library calls, `Unit`'s cases hoist into `Statement`, `Chain` is deleted. A Swift-only core has statements that are expressions, `if`, `for`, `while` and `switch`. |
| **env** (24) | `env` is special everywhere: a scope binding kind, `Statement.setEnvironment`, `$NAME`, a checker symbol with its own member types, and `ShellLayer.environment` | `Shell+Expressions` (10), `Shell+Environment`, `Shell+Statements`, `TypeChecker` (3 files), `Shell+Builtins` | Embedding step 6, host objects with dynamic members: a `SwishObject` can assign members and say their types, and `env` is registered as one. The special binding, statement and symbol go; `$NAME` is the desugarer's `Environment["NAME"]`. The same feature serves JSON as a real type (foundations.md) and an embedder's own objects. |
| **jobs** (25) | `Job` named in the checker and `await`'s operand, `Job.members` and `Job.columns` read by name, a `jobs` scope binding, and `commandAccess` | `Shell+Expressions` (11), `TypeChecker` (3 files), `Display`, `Scope`, `Shell+Builtins`, `Shell+Statements` | Async plan steps 5 and 6 with dynamic members: `Job` becomes an ordinary registered type that declares its members and its `Tabular` columns itself, `jobs` a registered global, `await` typed by a handle protocol. The `commandAccess` uses leave with grammar. |
| **status** (4) | Every statement returns an exit status, `lastStatus` stores it, `exitCode` maps it to a signal | `Shell+Statements`, `Shell+Environment` | After flatten, statements return nothing; the shell records the status of command statements per task (async.md, task context); `exitCode` moves with the shell half of `Shell+Environment`. |
| **file** (1) | The `.filePath` expression reads the shell's `scriptPath` | `Shell+Expressions` | Embedding step 2: the file name is state of the `Interpreter`, set by `eval(source, file:)` and by running a script. |
| **history** (1) | The `ShellContext` lent to library functions carries `history` | `Bridge+Conversions` | Embedding step 4: `ShellContext` splits. The core lends output and display facts; `history(in:)` moves to the shell's library and asks the shell for its history. |
| **plugin** (6) | `import Name from path` loads a dylib: a statement, the parser, the checker, the interpreter | `Syntax` (2), `TypeChecker+Statements`, `Shell+Statements` | Embedding steps 5 and 7: `import Name` is resolved by the host (`loadModule`); the dylib loader is the shell's implementation of it, and the `from path` form is shell syntax. |
| **commands** (1) | `commandFunctions(named:)`, the lookup of functions callable as command words | `Shell+Scopes` | Leaves with grammar at step 4. |

### Files that stay but must split

Four checked files hold both halves and are split at step 4 of the embedding
plan, when their shell half moves:

- `Interpreter/Shell+Environment.swift`: string interpolation (`expand`) is
  core; `environmentRecord`, `exitCode`, `withEnvironment`, redirect resolution
  and word expansion are the shell's.
- `Interpreter/Shell+Expressions.swift` and `Shell+Statements.swift`: the
  evaluator is core; the shell cases in them (env, jobs, pipelines, chains,
  statuses) go as their groups exit, which is why they carry the most
  allowances.
- `Builtins/Shell+Builtins.swift`: installing the prelude's functions, the JSON
  access helpers and `declaredCase` are core; the `jobs` binding is not.

## The order the exits come in

1. **Embedding step 2** (language state into `Interpreter`): `file`.
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
