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

### Script values and types

- ``Value``
- ``ScriptType``

### Registering Swift functions, types and objects

- <doc:ExposingSwift>
- <doc:NativeBodies>
- ``HostSymbol``
- ``HostTypeBuilder``
- ``ScriptConvertible``

### Errors, symbols and declarations

- <doc:ReadingDiagnostics>
- ``Diagnostic``
- ``Symbol``
- ``Symbol/ID``
- ``Symbol/Attribute``
- ``Symbol/GenericParameter``
- ``Interpreter/Declarations``

### Output streams and styled text

- ``OutputSink``
- ``DisplayStyle``
- ``DisplayStyle/Attribute``
