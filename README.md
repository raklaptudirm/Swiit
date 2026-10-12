# Swiit

An embeddable interpreter for Swift, written in Swift. It reads Swift with
SwiftSyntax, checks it statically, and runs it in a process of your own, with
the standard library and whatever Swift code you bridge into it. It is the
language underneath [Swish](https://github.com/raklaptudirm/Swish), a shell.

- `Sources/Swiit`: the interpreter (`Interpreter`, `SwiitHost`, the bridges).
- `Sources/SwiitKit`: the value model, and what a host registers and converts
  through (`Value`, `SwiitConvertible`, `ExportedFunction`).

```
swift build
swift test
```

Not 1.0: a minor release may change the host API.
