# Functions and commands

Status: **implemented**, except Swift-side callables (milestone 8).

Swish has **one kind of callable with two call syntaxes**. A function is
defined once, and its command-line form is derived from its Swift signature.
Swift's argument labels already are command-line flags.

```swift
func greet(_ name: String, times: Int = 1, loud: Bool = false) -> String { … }

let s = greet("Rak", times: 2)     // expression mode: a Swift call
greet Rak --times 2 --loud         // command mode: the same function
```

## Signature → command line

| Swift signature | Command mode |
|---|---|
| `_ name: String` (unlabeled) | positional argument |
| `times: Int` | `--times 2` or `--times=2`; the word becomes the declared type by what that type declares (below), with an error if it isn't one |
| `loud: Bool = false` | the switch `--loud`, or `--loud false` |
| `color: Bool = true` | `--no-color` |
| `ignoreCase:` | `--ignore-case` (camelCase becomes kebab-case) |
| `_ files: String...`, `_ files: [String]`, `_ ids: Set<Int>` | the remaining positionals |
| default value | optional flag |
| no default | required; missing ones are reported by name |
| `name: String?` | an optional flag whose absence is `nil` |
| a runtime error | status 1, and the rest of the input is abandoned |
| a `Bool` result | the status: `false` is a failure, for `&&`/`\|\|` and `if` |
| return value | output to the pipeline |

`--` ends flag parsing, so `rm -- --weird-name` works.

**A word becomes the parameter's type by what the type declares,** not by
a list of types the shell knows:

- a failable initializer from text, `init?(_ description: String)`: `Int`,
  `Double`, `Bool`;
- Swift's rules for text literals, by the most specific literal protocol
  the type conforms to: any text for `String` or `FilePath`, one character
  for `Character`;
- a case's name, for an enum.

A type no word can be, like a range or a struct, is an error that points to
call syntax: `f(r: 1...3)`.

**Collection parameters take a repeated flag:** `--include a --include b`
for `include: [String]`. A collection is any type an array literal can be,
made from its items (an Array, a Set), and unlabeled, it takes the
remaining words. There's no comma splitting, so values containing commas
need no escaping, and this matches Unix tools like `grep -e` and `curl -H`.

**A dash followed by a number is a value** unless the callable has a short
flag with that name: `calc -5` passes `-5`. Externals always receive their
argv verbatim.

Short flags and help text can't be derived from a signature:

```swift
/// Repeats a greeting.
/// - Parameter times: how many times to greet
func greet(_ name: String, @flag("n") times: Int = 1) -> String
```

`@flag("n")` gives a labeled parameter a short flag: `-n 3`, `-n3`, and
switches bundle, as in `-lv`.

The `///` comment block directly above a `func` becomes `greet --help` (or
`-h`), along with a usage line per overload and every argument and option
with its type and default. A function that declares its own `help` label or
`-h` flag gets those arguments instead. The same metadata will drive tab
completion.

## Pipeline input

One parameter can be marked `@input`, and its type decides how the function
streams:

```swift
// Called once per item: a map/filter stage (PowerShell's `process` block).
func where(@input _ item: Value, _ predicate: (Value) -> Bool) -> Value?

// Receives the whole stream: an aggregating stage (PowerShell's `end` block).
func sort(@input _ items: [Value], by key: KeyPath) -> [Value]
```

A per-item function returning `nil` outputs nothing for that item, so
filters return an optional. Outside a pipeline, the `@input` parameter is an
ordinary argument: `where(x, { $0.size > 1.mb })` in expression mode, or a
positional in command mode when the function starts the pipeline
(`double 21`, `total 1 2 3`).

What flows between stages:

- **Between Swish functions:** values, pulled one at a time, so `… | prefix 5`
  stops upstream work early. A whole-stream function's list result flows
  out as its elements.
- **From an external program:** its output lines, as Strings, converted to
  the `@input` type like command-line arguments (`seq 5 | double`).
- **To an external program, or the terminal:** one line per item, with lists
  one line per element. When the reader exits early (`… | head -1`), the
  function stops being called.
- **A value can start a pipeline:** `[3, 1, 2] | sorted`, `"text" | tr a-z A-Z`.
- A function without `@input` in the middle of a pipeline ignores its input.

For now, a pipeline can have only one run of consecutive Swish functions
(`ext | f | g | ext` works, `f | ext | g` doesn't): Swish code runs on one
thread, and two runs separated by an external would each wait on the other.

## Choosing the syntax

What parses decides, not the first character. A unit is an expression if
one parses there and the unit ends after it; otherwise it's a command:

- `ls -la` and `git-lfs version`: no expression parses within the first
  word, so it's a command named by that word.
- `"/opt/My App/run" x`: a word follows the string, so the string names
  the program; `2to3 x` and `7zip a` too, not being numbers.
- `x -1`, `"text"`, `[1, 2]`, `.directory`: expressions, ending the unit.
- A function's name is a command unless it's called or read there:
  `greet Rak` and `greet` run it, `greet(…)` and `greet.self` are
  expressions. `name(` with **no space** is always a call.
- `^name` and `$name` (`$EDITOR notes`) always start a command.

A word that starts like an expression but isn't one, like `1...2...3`, is
a command too; if no program has that name, the error says why it isn't
an expression, rather than only that the command wasn't found.

- Method calls (`x.foo()`) are always expression mode.
- **External programs** are callable only in command mode. In expression
  mode they need `$(…)`, so `git(…)` can never secretly spawn a process.

## Name lookup in command mode

1. Swish functions and builtins
2. External programs on `PATH`

`foreign name` (or `^name`) forces the external, so defining `func ls` never makes `/bin/ls`
unreachable. `which name` reports what a name resolves to, listing every
overload of a function.

Structured builtins deliberately keep their familiar Unix names and shadow
the tools: a bare `ls` or `ps` gives records, so
`ls | filter { $0.size > 1.mb }` works out of the box. `foreign ls` gets `/bin/ls`.

## Methods as pipeline stages

After a `|`, a stage's name can be a method of what's piped in, with the
input as `self`: `x | name args` is `x.name(args)`. Lookup goes:

1. **The items' methods, collected.** A stream, list, or an Output's
   lines has an Array's members, Swift's own: `xs | max`,
   `| contains 2`, `| joined(separator: ",")`, `| first(where: …)`,
   `| sorted`. The shell's streaming versions come first where they
   exist: `filter`, `map`, `compactMap` and `prefix` stream, so
   `yes | prefix 3` ends; `select`, `get`, `uniqued` and `sorted(by:
   \.size)` are its additions. `map` and `sorted` are Swift's: `map`
   keeps nils, and there's no `--reverse`, `| reversed` instead. A single
   value that isn't a sequence is the receiver itself:
   `"a b" | split(separator: " ")`.
2. **Each item's methods:** a struct's (`points | describe`), a job's
   (`jobs | cancel`), or a Swift type's (`names | uppercased`). What each
   returns flows on. A mutating method can't be piped, since a piped
   value isn't a variable.
3. **Functions, then programs,** as for the first command. `foreign sort`
   still reaches `/usr/bin/sort`.

The checker decides which, from what flows in; the interpreter does what
it recorded, and never guesses. Items of a type the checker can't see
(`Any`) have no methods as stages.

Methods come before functions so a `func sorted` can't silently change
`ls | sorted`. Without a `|` there's nothing for a method to work on, so
`sorted` alone is an error that says so.

A stage can also be written as a call: `ls | sorted(by: \.type)`,
`points | scaled(by: 2)`. Its arguments bind by Swift's rules, and the
input fills the `@input` parameter as it does for a command. In both
syntaxes a trailing closure can fill a labeled parameter, as in Swift:
`ls | sorted { $0.size < $1.size }` passes it as `by:`, and
`count { $0 > 1 }` as `where:`.

Only names defined with `func` are callable in command mode. A closure
stored in a variable is called in expression mode (`f(x)`). This keeps
command-mode lookup static, which also lets highlighting and completion know
what a name is before it runs.

## Finding functions

`help` lists every function you can call as records (`name`, `source`,
`summary`, `usage`), so it can be filtered like anything else: the
builtins, shell builtins like `cd`, your own functions (source `yours`),
and imported ones (source: their module). `help name` shows what
`name --help` does, and for a program, where it is and where to look.
For a type, `help String` or `help FilePath` lists its members, with
Swift's own documentation, and `help Point` a struct of yours; `members`
describes the items piped into it the same way. A sequence's methods
(`sorted`, `select`) are members, so they're under `help Array`, not in
the list of functions, and names you can't write, like `$json`, are the
shell's own and aren't listed.

```swift
help
help | filter { $0.source == "Tools" }
help first
```

## Overloads

Declaring a `func` whose signature (labels and types) differs from an
existing one in the same scope adds an overload; the same signature
replaces it, which is what redefining at the prompt should do.

A call tries every overload and keeps the ones that accept the arguments.
Among those, the most specific wins: in expression mode, the one needing
fewest conversions (so `f(5)` prefers `Int` over `Double`); in command mode,
the one taking fewest arguments as plain text (so `f 5` prefers `Int` over
`String`). A tie is an error that lists the candidates; there is never a
silent guess.

## Swift-side callables

Builtins, and bridges for imported packages, are ordinary Swift functions
registered with a macro that records their signature at compile time. Swift
has no runtime reflection for function signatures, so a macro is what makes
the derived command-line form possible.

```swift
@SwishExport(input: "item")
func where(_ item: Value, _ predicate: Closure) throws -> Value? { … }
```

The bridge generator for imported packages emits the same registrations, so
library functions get flags, help and completion without anything written
by hand.

## Why not separate `func` and `command` keywords

- A separate keyword forces a choice up front that is often wrong: a helper
  later needs to be a command, or the other way round.
- Imported library functions would never be usable as commands.
- PowerShell's worst gotcha comes from the lack of a real call syntax: its
  functions are command-only, so `Add(1, 2)` passes one array argument.
  Supporting both syntaxes properly rules this out.
