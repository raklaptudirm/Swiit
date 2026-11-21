# ``Swiit``

A Swift interpreter you embed in your own program: register Swift functions and values, evaluate Swift source, and get back a value or a diagnostic.

## Overview

Swiit parses Swift with SwiftParser, type-checks it, and runs it. A script cannot open files, start processes or read environment variables
unless you register a function that does. It can use only the names you register, and `print` writes to the ``OutputSink`` you gave it.

```swift
let swiit = Interpreter(host: Interpreter.Host(output: OutputSink { print($0, terminator: ""); return true }))
swiit.register("double") { (n: Int) in n * 2 }
let answer = try swiit.evaluate("double(21)")   // 42
```

## Topics

### Creating and running an interpreter

- <doc:EmbeddingSwiit>
- ``Interpreter``
- ``ScriptTask``

### Values and types

- ``Value``
- ``TypeExpression``
- ``TypeRef``

### Symbols

- ``Symbol``

### Registering Swift functions, types and objects

- <doc:ExposingSwift>
- <doc:NativeBodies>
- ``BridgedValue``
- ``BridgedType``
- ``TypeImplementation``
- ``SymbolImplementation``

### Errors and output

- <doc:ReadingDiagnostics>
- ``Diagnostic``
- ``OutputSink``

### What Swift code runs

- <doc:SwiftSupport>
