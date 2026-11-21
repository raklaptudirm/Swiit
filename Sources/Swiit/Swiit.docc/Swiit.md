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

### Creating and configuring an interpreter

- <doc:EmbeddingSwiit>
- ``Interpreter``
- ``Interpreter/Host``
- ``Interpreter/Limits``

### Evaluating source and stopping a run

- ``Interpreter/evaluate(_:limits:onValue:onError:completion:)-670lm``
- ``Interpreter/Cancellation``
- ``ScriptTask``

### What Swift code runs

- <doc:SwiftSupport>

### Script values and types

- ``Value``
- ``TypeExpression``
- ``TypeRef``

### Describing symbols and types

- ``Symbol``
- ``Symbol/Kind``
- ``Symbol/Attribute``
- ``Symbol/Constraint``
- ``Symbol/Nominal``
- ``Symbol/Nominal/Kind``
- ``Interpreter/Declarations``

### Registering Swift functions, types and objects

- <doc:ExposingSwift>
- <doc:NativeBodies>
- ``BridgedType``
- ``TypeImplementation``
- ``SymbolImplementation``
- ``BridgedValue``

### Errors

- <doc:ReadingDiagnostics>
- ``Diagnostic``

### Output streams

- ``OutputSink``
