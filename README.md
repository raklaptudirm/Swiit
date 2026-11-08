# Swiit

An embeddable interpreter for Swift, written in Swift. It reads Swift with
SwiftSyntax, checks it statically, and runs it in a process of your own, with
the standard library and whatever Swift code you bridge into it. It is the
language underneath [Swish](https://github.com/raklaptudirm/Swish), a shell.

The documentation, with guides to embedding it and the whole host API, is at
<https://raklaptudirm.github.io/Swiit/>.

- `Sources/Swiit`: the interpreter: the language, the host API (`Interpreter`,
  `Value`, `HostSymbol`, `ScriptConvertible`), the bridges to Swift's own types,
  and the DocC catalog (`Swiit.docc`).
- `Sources/SwiitBridge`: `swiit-bridge`, which makes the bridges from the symbol
  graphs of Swift's modules (`Scripts/bridge`).
- `Benchmarks`: `swiit-benchmarks`, run with `swift run -c release swiit-benchmarks`.

```
swift build
swift test
```

Not 1.0: a minor release may change the host API.
