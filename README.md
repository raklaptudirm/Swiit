# Swiit

An embeddable interpreter for Swift, written in Swift. It reads Swift with
SwiftSyntax, checks it statically, and runs it in a process of your own, with
the standard library and whatever Swift code you bridge into it. It is the
language underneath [Swish](https://github.com/raklaptudirm/Swish), a shell.

- `Sources/Swiit`: the interpreter (`Interpreter`, `SwiitHost`, the bridges).
- `SwiitKit`: the value model and plug-in ABI (`@SwiitExport`, `@SwiitObject`),
  a package of its own so that a host and its plug-ins share one copy.
- `Docs`: the design notes, starting with [embedding](Docs/embedding.md) for
  the public API.

```
swift build
swift test
swift test --package-path SwiitKit
```

Not 1.0: a minor release may change the host API. See
[Docs/extraction.md](Docs/extraction.md) for how this repository came to be.
