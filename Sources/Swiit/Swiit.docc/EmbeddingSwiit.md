# Embedding Swiit in a Swift program

Create an ``Interpreter``, register the Swift functions a script may call, and evaluate source text.

## Create an interpreter

A new ``Interpreter`` knows Swift's syntax and standard library, and nothing else: no files, no processes, no environment variables. Its
``Interpreter/Host`` holds the output and error streams (each an ``OutputSink``) and a `shouldStop` closure that is asked before every step.
Its ``Interpreter/Limits`` cap the number of steps, the call depth, the running time, the bytes written and the number of tasks. A run can be given limits of its own, as in `evaluate(_:limits:)`, in place of those; a call to a function from outside a run is a run of its own.

```swift
let swiit = Interpreter(
    host: Interpreter.Host(output: OutputSink { text in print(text, terminator: ""); return true }),
    limits: Interpreter.Limits(maxSteps: 1_000_000, timeLimit: .seconds(2))
)
```

## Register functions and types

``Interpreter/register(_:labels:throwing:_:)-f2lx`` makes a Swift closure callable by name. Each parameter and the result must conform to
``ScriptConvertible``. `Int`, `Double`, `String`, `Bool`, `Date`, `Value`, optionals, arrays and dictionaries of those, and `CaseIterable` enums
already do, and a `Hashable & Sendable` type can adopt it with `extension URL: ScriptConvertible {}`. To expose a Swift value
type, a live object or a set of declarations, see <doc:ExposingSwift>.

## Evaluate source

``Interpreter/evaluate(_:limits:onValue:onError:completion:)-670lm`` runs source text and returns the ``Value`` of its last statement when that statement
is an expression that ran, and nothing otherwise. Functions, types and variables it declares stay available to the next call.

A prompt or a script runner passes closures as well. `onValue` is called with each top-level expression's value, and with the ``Symbol`` of the function that statement called
(if it is a call), as the statement finishes. The last value is returned too. `onError` is called for a runtime error, and returning `true` carries on with the next statement. `completion`
runs after the last statement and before the program's top-level `defer` blocks.

## Stop a run

A run stops when it reaches a limit, when `shouldStop` returns `true`, or when any thread calls ``Interpreter/cancel()``. It then throws a
``Diagnostic`` of kind `limit` or `cancelled`.
