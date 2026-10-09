# Swish types are Swift types

Status: **in progress**, as phase 5 of [static types](types.md): step 1's
first slice is built (see [Steps](#steps)). It replaces
"typed plugins" there and the old milestone 9 (URLs, versions, bridges).

Decided:

- **One type system: Swift's.** The checker has no types of its own.
  `Int`, `String`, `[T]`, `Date`, `URL` are the standard library's and
  Foundation's, with every member Swift gives them; a package's types are
  its own; Swish's own (`FileSize`, `Output`, `FileEntry`, `Job`) are
  declared in Swift, in SwishKit, and read the same way.
- **Representation: generated Swift twins.** The interpreter keeps its own
  representation of values; at the boundary with Swift, values convert,
  and a struct or enum declared in Swish gets a generated Swift twin, so it
  can go where Swift wants a real type (`decode(Config.self, …)`,
  `Set<Point>`).

Any Swift package or SDK module is used from Swish with nothing written for
Swish: no `@SwishExport`, no wrapper package.

```swift
"a,b,c".split(separator: ",")              // Swift's own String and Sequence methods
Date().addingTimeInterval(3600)

import Foundation
let url = URL(string: "https://swift.org")!
url.appendingPathComponent("docs").host    // "swift.org"

struct Config: Decodable { var name: String; var port: Int }
let config = try JSONDecoder().decode(Config.self, from: Data($(cat config.json).text.utf8))

import Yams from "https://github.com/jpsim/Yams"
let doc = try Yams.load(yaml: $(cat config.yml).text)
```

`@SwishExport` stays: it's the way to shape a command line (`@Flag`,
`@Input`, doc comments as `--help`) for a package written for Swish.

## One type system

- **The standard library and Foundation are read, not written down.** The
  checker's hand-written members (`count`, `lines`, `first` and the like)
  and most of the prelude give way to Swift's own declarations, read from
  their symbol graphs. So `filter`, `map`, `sorted(by:)`, `contains`,
  `split`, `uppercased()` and the rest are Swift's, with Swift's
  signatures and overloads.
- **Swish's own types are Swift declarations,** in SwishKit: `FileSize`,
  `Output`, `Status`, `FileEntry`, `ProcessEntry`, `Job`, `Member`,
  `Help`. What only a shell needs (`sorted(by:)` with a key path, `get`,
  `select`, `uniqued()`, `prefix` with a default) are Swift extensions
  there too. The prelude keeps only what isn't Swift: which builtins are
  commands, and their command lines (`@flag`, `@input`).
- **Types declared in Swish** are ordinary types to the checker: a Swish
  `struct Config: Decodable` is a `Config` that is `Decodable`, and can be
  passed where Swift wants one.
- **What Swish adds to Swift's rules:** commands and pipelines (their
  stages typed as now), `$(…)`, an `Output` being its text where a String
  is wanted, and literal command-line words converted to their
  parameters' types.

## Why glue is still compiled

Swift can read a value's fields at run time (`Mirror`), but it can't call a
function or method by name. So calling Swift from an interpreter takes
compiled glue: a thunk per function that converts arguments, calls it and
converts the result back. Swish writes and compiles that glue itself.

Compiling Swish itself to Swift (so every value would be a native Swift
value) would remove the conversions, but costs a compile per entry at the
prompt and a second execution engine; the twins below get the same result
for types at the boundary without it. It remains possible later, for
scripts, reusing the twins.

## How

1. **Resolve and build.** `import Name from "url"` (or a path, or an SDK
   module with no `from`) resolves the package with SwiftPM, pinned in a
   lock file beside the script or in the shell's state directory, and
   builds it. The standard library and Foundation are always there.
2. **Read its declarations.** `swift package dump-symbol-graph` (for
   packages) or `swift-symbolgraph-extract` (for SDK modules and the
   standard library) gives every public declaration with its full Swift
   signature: parameters, labels, generics and constraints, `throws`,
   `async`, doc comments. The checker loads these as it loads the
   prelude, so calls are checked against Swift's real signatures, and
   `help` and completion know them. Both tools come with the Command Line
   Tools. A graph can be large (Foundation's is 44 MB of JSON), so it's
   read once into a compact index, cached, and looked up by name as names
   are used.
3. **Generate glue for what's used.** After checking, the shell knows each
   declaration the program touches, with concrete generic arguments
   (`JSONDecoder().decode(Config.self, from:)`). It writes a Swift file
   with a thunk for each, and a twin for each Swish type that crosses, and
   compiles it into a dylib against the packages.
4. **Cache it.** Dylibs are cached by the symbols and twins they hold, the
   packages' versions and the compiler's. The first use of an API pays one
   compile (a second or two, with a progress hint as for "Building…");
   after that it loads at once, in any shell.

## Values across the boundary

- **Values with a Swish representation convert:** numbers, `String`,
  `Bool`, `Date`, arrays, dictionaries, optionals, tuples, and the values of
  Swish-declared structs and enums (through their twins).
- **Swift twins:** for a struct or enum declared in Swish that crosses
  into Swift, the glue declares a Swift type with the same name, fields
  (or cases), types and conformances (`Equatable`, `Hashable`, `Codable`,
  `Comparable` for enums), and converts values to and from it at the call.
  Methods stay in Swish; a Swift API that calls one (a `Comparable` twin's
  `<`) is out of scope at first.
- **Everything else is held as it is:** a Swift value the interpreter has
  no representation for (`URL`, `Data`, `Yams.Node`) is kept as the Swift
  value, of its Swift type, and passes back into Swift unchanged. To the
  checker and to you it's just a `URL`.
- **Closures:** a Swish closure passed where Swift wants one is wrapped by
  the thunk, so `swiftArray.map { … }` works.

## Steps

1. **The standard library's members on Swish values**, from its symbol
   graph and generated glue, replacing the hand-written member tables.
   *Built so far:* `swiit-bridge` (Sources/SwiitBridge) reads the graph
   and writes Sources/Swiit/Bridge/Generated/StandardLibrary.swift;
   `run bridge` reruns it. It bridges `String`,
   `Substring`, `Character`, `Int`, `Double`, `Bool`, `Array`,
   `ArraySlice`, `Set`, `Dictionary`, `Optional`, `Range` and
   `ClosedRange` (647 members). A member is bridged if every type in its
   signature is one of those, a generic parameter, a tuple or a closure of
   them, and its constraints are ones Swish can check:
   - **Generic code is compiled once**, with Swish's values standing in
     for every generic parameter: a `Set<Int>` is held as a `Set<Value>`.
   - **Same-type constraints** fix a parameter (`[String].joined` through
     `Element == String`), or say what a sequence parameter holds:
     `union<S: Sequence>(_:) where S.Element == Element` takes
     `some Sequence<Element>`, so a list, a range, a set or a String's
     Characters.
   - **Conditional conformances** are checked with their conditions: a
     `ClosedRange` is a Sequence, with `map`, `filter` and the rest, only
     when `Bound: Strideable` with a signed stride, which for Swish means
     `Int`. So `1...5` is a `ClosedRange<Int>` (lazy, not a list) and
     `(1.0...2.0).contains(1.5)` works but `for x in 1.0...2.0` doesn't
     type-check. (The graph doesn't list a range's collection members, so
     they're read from the protocols, where the type has none of its own.)
   - **Values keep Swish's form where it has one:** arrays, dictionaries,
     optionals and tuples convert at the call; `Set`, `ArraySlice` and
     ranges are held boxed, as the Swift values.
   - **Dictionaries are Swift's,** unordered: iterating one (`for`, `map`,
     `first`) goes in Swift's order, which changes from run to run. Only
     showing one sorts it, by key: at the prompt, in a string, piped to a
     program or written by `to json`, so output is the same every run.
     `keys` and `values` are still arrays rather than Swift's views.
     `OrderedDictionary`, from swift-collections, is next, for when order
     matters.
   - **Other modules' types are held boxed,** by their full name:
     swift-system's `FilePath`, `FilePath.Component` and
     `FilePath.ComponentView` (81 members, in
     Sources/Swiit/Bridge/Generated/SystemPackage.swift). It's swift-system's
     until the standard library's
     ([SE-0529](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0529-filepath-in-stdlib.md))
     ships, when swift-system's becomes a typealias for it and keeps these
     members as extensions. `FilePath.Root` is left out, since SE-0529
     calls it `Anchor`.
   - **A string literal is whatever `ExpressibleByStringLiteral` type is
     wanted,** as in Swift: `let p: FilePath = "/tmp"`, or a `FilePath`
     argument, made with `init(stringLiteral:)`. A `String` value doesn't
     convert: `FilePath(s)`. On a command line, a word is what a literal
     would be, so `show a/b.txt` works for `func show(_ path: FilePath)`.
   - **Swish adds a few members of its own** to bridged types, as an
     `extension` would, listed in Sources/Swiit/Bridge/Extensions.swift
     and checked and called like Swift's: `"text".styled(.red, .bold)`.
   - **A bridged sequence flows as its elements** in a pipeline, as a
     list does: `p.components | map(\.stem)`.
   - **Mutating members change their variable,** as struct methods do:
     the glue calls Swift on a `var` copy and gives back the result and
     the changed receiver, which the shell puts back where it came from
     (`xs.append(1)`, `s.xs.append(1)`, `m[0].append(1)`). So a receiver
     must be a `var`, or part of one. A settable property gets a setter
     the same way: `p.extension = "md"`. `@discardableResult` members
     (`removeLast()`) don't show what they give when a statement is just
     the call.
   Key paths (`\.count`) read the same bridged properties. Swift's members
   come before the prelude's; the prelude's shell additions
   (`sorted(by: \.size)`, `prefix` with a default, `select`, `get`,
   `uniqued`) remain. Left for the next slices: `inout` parameters,
   operators (`reduce(0, +)`), `Slice` and the other lazy and view types
   (`enumerated()`, `lazy`, a Set's `dropFirst`), indices, Foundation.
2. **Swish's own types in SwishKit**, read the same way; the prelude
   shrinks to command lines.
3. **Packages and SDK modules** imported by URL, path or name.
4. **Twins** for Swish types that cross into Swift.

## Not at first

`inout` parameters, operators, protocols with associated types as values
(`some Collection`), Swift calling back into a Swish type's methods,
subclassing Swift classes from Swish, and async beyond waiting for it to
finish.
