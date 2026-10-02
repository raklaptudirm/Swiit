# One foundation for everything callable

Status: **in progress**: steps 1 to 3 are done. It follows on from [swift-interop.md](swift-interop.md),
whose step 2 ("Swish's own types in SwishKit") it takes all the way.

Swish grew several ways for a name to be callable, each with its own lookup,
help and command-line rules. This plan folds them into one: **every function,
method and type Swish offers is a Swift declaration, read from a symbol
graph**. The standard library's, swift-system's, Swish's own builtins and a
plugin's all arrive the same way, so they behave the same way at the prompt,
in a pipeline, on the command line and in `help`.

## Where things stand

Five registries, each with its own rules:

| What | Declared | Body | Pipes | Command line | `help` |
|---|---|---|---|---|---|
| Shell builtins (`cd`, `umask`, `source`, …) | a name set | Swift, text in and out | no | its own parsing | a hand-written table |
| Prelude functions (`ls`, `ps`, `pwd`, …) | Swish text in Prelude.swift | Swift, found by name | as functions | from the signature | yes |
| Prelude `extension Sequence` (`map`, `sorted`, …) | Swish text | Swift, found by name | yes | from the signature | yes |
| Bridged members (`String`, `Array`, `FilePath`, …) | Swift's symbol graphs | generated glue | **no** | — | **no** |
| Swish's extensions (`String.styled`) | hand-written `BridgedMember`s | Swift | no | — | no |

Plugins are a sixth, with `@SwishExport` and their own loading.

What that costs, found by trying it:

- **Pipes only reach ten methods.** A stage after `|` finds the prelude's
  `Sequence` methods, then methods of the items' Swish structs. Swift's
  own methods aren't looked for, so `xs | max`, `| contains(2)`,
  `| joined(separator: ",")`, `| first(where:)`, `| reduce(0) { … }` and
  `"a b" | split(separator: " ")` fail, with a misleading "is an external
  command" error.
- **Flags only take a few types.** A command-line word is converted by a
  hand-written switch over `Int`, `Double`, `Bool`, file sizes, dates, enums
  and string literal types. `--r 1...3`, a `Set`, a `Character`, a tuple
  or a struct fail. `func f(n: Int?)` still demands `--n`; an unlabeled
  `[Int]` won't take `f 1 2`; `--v false` isn't a Bool.
- **`help` shows 34 entries:** the builtins and the prelude's `Sequence`
  methods, with two internals (`$json`, `$jsonAs`) among them. None of the
  700-odd bridged members, and no way to ask what `String` can do.
- **Types are declared twice.** `FileEntry` is a Swish struct in the
  prelude and a private Swift `Encodable` struct beside `ls`, whose record
  is then patched (`type` made an enum, `path` a FilePath). `ProcessEntry`,
  `Help` and `Member` too.
- **Swish's own value kinds sit beside Swift's.** `filesize`, `date`,
  `output` and `record` are cases of both `Value` and `TypeAnnotation`,
  where the goal is one type system, Swift's.
- **The prelude shadows Swift.** Its `map` drops nils, which is Swift's
  `compactMap`, and its `sorted` has `--reverse`, so `xs.map` in Swish isn't
  Swift's.
- **The checker knows some names.** `select` has a hand-written type rule,
  and JSON is a fake struct whose field access is rewritten into calls to
  `$json`.
- **Display knows some names.** Default columns come from a table in
  Display.swift (`"FileEntry": ["name", "type", "size", "modified"]`), and
  colors from `FileType`, `JobState` and `FilePath` by name. A struct of
  your own can't say how it's shown.
- **Resolution is done twice.** The checker records how a stage resolves,
  but the interpreter keeps a fallback that guesses (`itemsMayHaveMethod`).

## Decided

- **One source of callables: Swift declarations, read from symbol graphs.**
  The checker, the interpreter, completion and `help` all ask the same
  registry.
- **Swish's standard library is a Swift module**, bridged like swift-system:
  `ls`, `ps`, `pwd`, `history`, `readLine`, their result types, `FileSize`,
  `Output`, `FileType`, `TextStyle`, `String.styled`, and the shell's
  additions to `Sequence` (`select`, `get`, `uniqued`, `sorted(by: \.key)`).
  Declared once, in Swift, with doc comments that `help` shows. That
  retires the prelude's text, bodies found by name, the duplicate structs
  and Extensions.swift. It's what a plugin does, so
  builtins and plugins become one mechanism, and the plugin ABI is the
  shell's own.
- **`map` and `sorted` are Swift's.** `map` keeps nils (`compactMap` drops
  them); `sorted()` and `sorted(by:)` take no `--reverse`. The shell adds
  only what Swift doesn't have, under names Swift doesn't use. `sorted(by:
  \.size)`, sorting by a key path, stays as an addition, since Swift has
  no such overload.
- **A pipe stage is a method call.** `input | name args` is:
  1. a member of the input, collected (`[Element]`, or the value itself if
     it isn't a sequence): `xs | max`, `| joined(separator: ",")`;
  2. else a member of each item, applied to every one: `names | uppercased`;
  3. else a function taking `@input`;
  4. else a program.

  The checker decides, from the input's type, and the interpreter does what
  it recorded; there's no guessing at run time.
- **A command-line word converts by protocol, not by a list of types.**
  - It becomes any type that's `LosslessStringConvertible` (`Int`,
    `Double`, `Bool`, `Character`, …), `ExpressibleByStringLiteral`
    (`FilePath`) or `RawRepresentable` with such a raw value, or an enum
    by case name.
  - An optional parameter is an optional flag: absent is nil.
  - A list or Set parameter takes a repeated flag, or, unlabeled, the
    remaining words.
  - `--flag value` works for a Bool as for anything else, beside `--flag`
    and `--no-flag`.
  - Anything else (ranges, tuples, dictionaries, structs) is an error that
    points to call syntax: `f(r: 1...3)`.
- **`help` comes from the registry.** `help` lists commands: functions,
  builtins and plugins' exports, with the first line of their doc comments;
  names starting with `$` are internal and aren't listed. `help name` shows
  one in full. `help String`, `help FilePath` or `help Array` shows a type's
  members, from Swift's own documentation.
- **A type says how it's shown**, through protocols in SwishKit: the columns
  a table shows by default, and a style. Swish's types adopt them, and so
  can yours.

## What stays special

The things that make it a shell rather than Swift: the two parsing modes,
`$(…)`, redirects, job control, `try` applied to a command, and the
builtins that change the shell itself (`cd`, `exit`, `umask`, `ulimit`,
`exec`, `source`). Those builtins become Swift functions in the standard
library too, so they get flags, help and completion like the rest; that
they change the shell is what they do, not how they're found.

## Steps

1. **Pipes resolve to members**, by the rule above, in the checker, with
   the interpreter's fallback removed. `map` and `sorted` become Swift's.
   *Done.* The prelude's `filter`, `map`, `compactMap` and `prefix` still
   come first, since they stream and an Array's members need all their
   input; where theirs doesn't fit, Swift's is tried, and the error shown
   is the prelude's unless its overloads didn't line up at all.
2. **Flags convert by protocol**, with optional, list and Bool fixes.
   *Done.* The generator reads what text can make of each type from its
   declarations (a failable initializer from text, its literal protocols,
   an initializer from any sequence for collections), and the binder asks
   only that.
3. **`help` from the registry**, with `help Type`, and internals hidden.
   *Done.* `help Type` and `members` share one description of a type: a
   Swift type's members from the bridge, each with the first paragraph of
   Swift's own documentation, which the generator now keeps; a sequence's
   with the shell's additions; a struct's or enum's from its declaration.
   `members` still lists a file size's and an output's members by hand,
   until step 4 makes them Swift types.
4. **The standard library module.** The generator learns free functions,
   protocol extensions and SwishKit's parameter attributes (`@Flag`,
   `@Input`); the prelude's text, the native bodies, the duplicate structs
   and Extensions.swift go. `FileSize`, `Date` and
   `Output` stop being cases of `Value` and `TypeAnnotation` and are Swift
   types like the rest.
   *In progress.* Every type gets its protocols' members, and other
   modules' additions to a type are read too (`_StringProcessing`'s
   `contains`). `SwishStandardLibrary` is a Swift target the generator reads
   for free functions, structs and enums: `pwd`, `readLine`, `history`, `ls`
   and `ps`, with `FileEntry`, `ProcessEntry` and `FileType`, are done. A
   struct becomes a record, declared in Swish from its fields; a parameter
   of type `ShellContext` is lent by the shell; a `Partial` result carries
   per-item errors; `@Flag` and `@Rest` mark short flags and the rest of the
   arguments. Left: `TextStyle` and `String.styled`, `JobState`, the
   `Sequence` additions with their attributes, and the three value kinds.
5. **Display protocols**, replacing the table of columns and the colors
   chosen by type name.

Each step is its own change, tested on its own; each removes code rather
than adding a path beside the old one.

## Open questions

- **`select`'s type.** It gives a tuple of the fields picked, which Swift
  could only say with parameter packs over key paths: `select(\.name,
  \.size)`. Until then it keeps its rule in the checker, the one special
  case left there.
- **JSON.** A Swift enum with `@dynamicMemberLookup` would replace the fake
  struct and its rewriting, once the bridge can call dynamic members.
- **Builtins that change the shell** need the shell passed in. A parameter
  their glue fills, which Swish code never sees, is one way.
