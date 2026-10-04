# Static types

Status: **phases 1–4 implemented** (see [Phases](#phases)). This is the plan
for making Swish statically typed,
as Swift is: every expression, function and pipeline stage has a type
known before anything runs, and type errors stop a statement (or a whole
script) before it starts.

Decided:

- Anonymous records are **labeled tuples**; `["a": 1]` is a **Dictionary**.
- `Any` is **strict** (it needs `as?`, `as!` or `is`), and parsed JSON has
  its own **`JSON`** type.
- Fields are named with **key paths**: `sorted(by: \.size)`, and
  `sorted --by size` on a command line.
- **Builtins are generic** first; generics and protocols of your own
  come in a later phase.

## What it looks like

```swift
let files = ls()                              // [FileEntry]
let big = files.filter { $0.size > 1.mb }     // $0: FileEntry, from filter's signature
ls | sorted --by size | map(\.name)           // stage types: [FileEntry] → [FileEntry] → [String]
ls | select name size                         // [(name: String, size: FileSize)]
ls | sorted --by sise                         // error before running: FileEntry has no member 'sise'

func double(@input _ n: Int) -> Int { n * 2 }
seq 5 | double                                // lines → Int, converted per item as today
[Point(x: 1)] | describe                      // Point.describe, chosen before running

let config = try from(.json, $(cat config.json).lines)   // JSON
config.server?.port?.int ?? 8080
```

## Principles

1. **Swift's rules unless there's a reason.** Where Swish differs (command
   mode, pipelines, `$(…)`), the difference is written down here.
2. **Check, then run.** At the prompt, each entry is checked before it
   runs; a script is checked whole before its first statement runs. A type
   error runs nothing.
3. **Types are compile-time.** Runtime values stay as they are (`Value`);
   the checker only adds what it resolves (overloads, which method a stage
   is, the enum of a `.case`, key paths) to the tree the interpreter runs.
   Most of the interpreter doesn't change, and dynamic checks it does now
   become assertions the checker already guaranteed.
4. **Programs are text.** An external program's output is `[String]`
   (lines) and it reads text; that boundary stays dynamic by nature.

## The type language

| Type | Written | Notes |
|---|---|---|
| Basics | `Int`, `Double`, `Bool`, `String`, `FileSize`, `Date` | As now. Swift's literal rules: `1` is an Int unless context wants a Double; no implicit Int→Double otherwise. |
| Void | `()` or `Void` | What a function with no `->` returns, as in Swift. |
| Optional | `T?` | `nil`, `if let`, `??`, `?.` optional chaining (new). |
| Array | `[T]` | |
| Dictionary | `[K: V]` | New, with `K: Hashable`. `["a": 1]` is `[String: Int]`; a mixed literal needs a type, as in Swift. Swift's, so unordered; shown sorted by key. |
| Tuple | `(name: String, size: FileSize)`, `(Int, Int)` | New. Labeled tuples are the anonymous records: they show as table rows, work with `select`, and encode as JSON objects. |
| Function | `(Int, String) -> Bool`, `() throws -> T` | New as a written type; closures infer theirs from context. |
| Key path | `KeyPath<Root, Value>`, written `\.size` | New. |
| Nominal | structs, enums, `Job`, `Output`, plugin classes | Struct fields and methods are typed already; builtins get declared types (`FileEntry`, `ProcessEntry`). |
| Any | `Any` | Only `as?`, `as!`, `is`, and passing it along. |
| JSON | `JSON` | What `from json` gives. A field (`json.name`, `json["name"]`) or element (`json[0]`) is a `JSON?`; `.string`, `.int`, `.double`, `.bool`, `.array`, `.object` read it as that type (nil if it isn't), and `.isNull` is true for a null or missing value. |

**Protocols** (builtin, for now): `Equatable`, `Hashable`, `Comparable`,
`CustomStringConvertible`, `Encodable`, `Sequence`. The basic types conform
as in Swift. A struct or enum conforms by declaring it
(`struct Point: Equatable`), and `Equatable`, `Hashable` and `Encodable` are
synthesized from its fields. `==` needs `Equatable`, as in Swift: today it
works on any two values.

## The checker

A new pass between parsing and running, over the same tree:

- **Environment.** Names → types, in scopes: variables, functions (their
  overloads' signatures), types. At the prompt the global scope persists
  between entries, as bindings do now.
- **Inference is Swift's bidirectional, local inference.** `let` takes its
  initializer's type; a closure's parameters and result come from the
  function type expected where it's written (`filter`'s `(T) -> Bool`
  makes `$0` a `FileEntry`); literals take their type from context, or
  default (Int, Double, String, `[T]`, `[K: V]`). There's no inference
  across statements or functions: function signatures are always written.
- **Generic calls** solve their type parameters by unifying arguments (and
  the expected result) with the signature, then check constraints:
  `sorted()` needs `Element: Comparable`.
- **Overloads** are resolved statically, as Swift does: the candidates
  that type-check, ranked by how exact the match is, ambiguity an error.
  This replaces today's run-time penalty ranking.
- **Results:** every expression gets a type; the tree is annotated with
  what was resolved. Errors carry a source position (line and column),
  so the AST gains source ranges; the parser already tracks spans for
  highlighting.

### Functions and structs

- A function's parameters are typed already. With no `-> T` it returns
  `Void`, as in Swift; today a single-expression body returns its value
  whatever the signature says. `return x` must match; missing returns are
  errors.
- `mutating`, `let` properties and `init` rules move from run time to the
  checker, with the same messages.

### Commands and pipelines

- **A command's arguments** are text, converted to the parameter's type.
  When a word is literal (`-n 2`, `--by size`, `high`), it's converted
  and checked before running; a word with `$var` or `\(…)` is converted
  at run time, as now. A closure argument is checked against the
  parameter's function type, so `$0` has the right type.
- **Stages have element types.** A function stage takes its `@input`
  parameter's type (`T` per item, or `[T]` as a whole) and produces its
  result's: an item function's result per item, a list result's elements.
  A program takes text and produces `String` lines. A value stage's type is
  the value's (a list's elements).
- **Method stages are resolved statically** from the upstream element
  type: `Sequence`'s methods, then the element type's methods, then
  functions, then programs. The run-time lookup for items' methods goes
  away, and so does the question of whether programs come first: the type
  says which method it is, or that there isn't one.
- **Into programs:** items are sent as text (records as rows, as now);
  anything `CustomStringConvertible` can be, and a function can't.
- **A pipeline as a statement** displays its output, as now. As a value,
  it's written as a call (`ls()`, `xs.filter { … }`), so its type is the
  call's.

### Builtin signatures

Builtins get declarations written in Swish, as a prelude the checker
reads, with native bodies. This also gives `help` and completion exact
signatures:

```swift
func ls(_ paths: String..., all: Bool = false, long: Bool = false) -> [FileEntry]
func ps() -> [ProcessEntry]

extension Sequence {
    func filter(_ isIncluded: (Element) throws -> Bool) rethrows -> [Element]
    func map<T>(_ transform: (Element) throws -> T) rethrows -> [T]
    func compactMap<T>(_ transform: (Element) throws -> T?) rethrows -> [T]
    func sorted<V: Comparable>(by key: KeyPath<Element, V>) -> [Element]
    func prefix(_ maxLength: Int = 1) -> [Element]
    func reversed() -> [Element]
    func count(where predicate: ((Element) throws -> Bool)? = nil) rethrows -> Int
    func get<V>(_ key: KeyPath<Element, V>) -> [V]     // map(key), kept for the command line
}
```

`select` can't be written this way, since it makes a tuple type from a
list of key paths (Swift would need variadic generics). It's typed by a
rule of its own: `select name size` on `[FileEntry]` is
`[(name: String, size: FileSize)]`. The same goes for `from json` (→ `JSON`)
and `to json` (`Encodable` → `String`).

`ls -l` is gone: it dropped the record's type so every field would show,
which a typed `[FileEntry]` can't do. `ls | table` shows every field.

`--numeric` and `--unique` on `sorted` go: `numeric` exists because lines
are text (`seq 10 | map { Int($0)! } | sorted` says what it means), and
`unique` becomes a method of its own, as `uniqued()`.

### Plugins

Phase 5 now uses packages without annotations ([swift-interop.md](swift-interop.md)).
For `@SwishExport` plugins, `SwishType` grows to match the type language (function types, tuples,
dictionaries, nominal types by name), and the ABI version goes to 2.
`@SwishObject` also emits each member's type. An exported struct used as a
result needs its fields' types: a `@SwishStruct` macro reads them from its
stored properties, the way `@SwishObject` reads a class. An `Encodable`
type without it can't be exported, since its shape isn't known until it's
encoded.

## Phases

Each phase ends with every test passing and the shell usable.

1. **Types and the checker's core.** *Done.* The type representation;
   each statement's line, for errors (columns later); checking literals,
   variables, operators, functions (with `Void` returns and "must return on
   every path"), structs, enums, optionals (with `!` and `?.`, brought
   forward from phase 4), arrays; errors before running. New values:
   tuples and dictionaries, and `let x: T = …`. Closures already take
   their parameter types from `filter`, `map` and the like. Programs,
   pipelines and builtins' results are `unknown` until phase 3, which fits
   anywhere, so nothing is refused for lack of a type.
2. **Functions as values.** *Done.* Function types (`(Int) throws -> Bool`);
   closures inferring parameters from context and their result from their
   `return`s; functions passed by name (an overloaded one picked by the
   type wanted); static overload resolution, ranked by how exactly the
   arguments match, with ties an error, and the choice written into the
   program so the interpreter makes the same one; Swift's rules for
   `throws`. The checker now hands back the program with its decisions in
   it (`.chosen` for an overload). User functions can't be `rethrows` yet;
   the builtins that take closures are.
3. **Generic builtins and typed pipelines.** *Done.* Builtin protocols and
   conformance declarations (`struct P: Equatable`; `==` needs Equatable,
   `<` and `sorted()` Comparable); key paths (`\.size`, and a field's name
   on the command line); the prelude (Prelude.swift), in Swish, declaring
   the builtin types (`FileEntry`, `ProcessEntry`, `Status`, `Error`,
   `Help`, `Member`) and every builtin's signature, generic where Swift's
   are, with Swift bodies found by name; stage types, from the input
   value, programs (lines) and each stage's result; method stages
   resolved from the input's type and recorded for the interpreter;
   command lines checked by binding their literal words as the
   interpreter will. `select`'s rule; `uniqued()`.
4. **Dynamic data.** *Done.* Strict `Any`: no members, indexing, calls or
   operators until it's cast with `as?`, `as!` or `is` (or widened with
   `as`), at Swift's precedence; the `JSON` type, whose field and element
   lookups the checker writes into lookups that give nil when missing;
   optional subscripts (`xs?[0]`), beside `?.` from phase 1.
5. **Swish types are Swift types.** See [swift-interop.md](swift-interop.md):
   one type system, Swift's, read from symbol graphs (the standard
   library, Foundation, SwishKit for Swish's own types, and any package);
   glue generated and compiled for the declarations used; generated Swift
   twins for Swish-declared types that cross into Swift. This replaces
   typed plugins; `@SwishExport` stays for shaping command lines.
6. **Later:** `func f<T: P>`, `protocol` declarations, `extension` on your
   types and the builtin ones.

## What changes for code that works today

- `func f() { 42 }` returns nothing; write `-> Int`.
- `==` between two structs needs `: Equatable`.
- `["name": "x", "size": 2.mb]` is an error (mixed dictionary); write a
  tuple, `(name: "x", size: 2.mb)`, or a struct.
- `sorted(by: "size")` becomes `sorted(by: \.size)`; `--numeric` and
  `--unique` go.
- Member access on `Any` needs a cast; on parsed JSON it gives `JSON?`.

## Decided while building phase 1

- **Type errors aren't catchable.** They're found before anything runs,
  so `do`/`catch` can't see them, as in Swift. Their status is 2, like a
  syntax error's.
- **`(try? $(cmd)) ?? "default"` is a String:** the Output's text or the
  default, since that's what it's always meant.
- **Records vs. tuples at run time:** a tuple is a record without a type
  name (unlabeled elements keyed by position), so tables, `select` and
  JSON treat tuples and structs alike.

- **Throwing follows Swift.** A `throws` function's calls need `try`, and
  a `try` must be in a `throws` function, a `do` with a `catch`, a closure,
  or at the top level (the prompt and a script's body handle errors, as
  Swift's main.swift does). `try? ` and `try!` handle them where they
  are. Plain `$(…)` still never throws; `try $(…)` and `try make` do, and
  count as throwing. Commands written as commands (`greet Rak`) aren't
  checked for `try`: a command's failure is its status.
- **Keeping plugins loading:** SwishKit keeps every public initializer it
  has shipped. Adding `isThrowing` to `ExportedFunction` added an
  initializer beside the old one, so plugins built before it still load.

- **Generics in the prelude only, for now:** `func f<T>`, `where`,
  `rethrows` and `extension Sequence` parse there, and are errors in your
  code until phase 6.
- **A variadic can come before labeled parameters,** as in Swift
  (`ls(_ paths: String..., all: Bool)`), since the label marks its end.
- **When no overload fits,** and only one of them lined up with the
  arguments (right labels and count), its error is the one shown, rather
  than a list of candidates.

## Open questions

- **Displaying `Void`:** a statement that's a call returning `Void` shows
  nothing, as now; is `()` ever shown?
- **Int and Double mixing:** follow Swift exactly (`let i = 1; i * 2.5` is
  an error), or allow Int→Double promotion? Plan: exactly Swift.
- **`$(…)` in string contexts:** today an Output is its text where a
  String is wanted. Keep that as an implicit conversion (Swift wouldn't),
  or require `.text`? Plan: keep it for String parameters and
  interpolation only.
