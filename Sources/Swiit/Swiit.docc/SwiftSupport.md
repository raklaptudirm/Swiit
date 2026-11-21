# Swift support

What Swiit does with Swift code, feature by feature, against the Swift compiler.

## Overview

Each row is a program that runs in the test suite, so the status is what the interpreter does today, and
a feature that starts to work fails its row until this page is updated. A row without a program states a
limit the tests cannot show. The page is written from the table in `Tests/SwiitTests/SwiftSupportTests.swift`.

- **Works**: it runs, with the result the compiler's program gives.
- **Rejected, as in Swift**: Swiit reports an error where the compiler does.
- **Not supported**: Swiit reports an error, or has no such API, where Swift accepts it.
- **Runs; Swift rejects it**: Swiit accepts a program the compiler rejects, so a program that
  compiles is fine here, and the reverse does not hold.

## Tasks and groups

| Feature | Status | Note |
| --- | --- | --- |
| `Task { }` and `value` | Works |  |
| `cancel()` and the cancellation error | Works |  |
| `Task.isCancelled` | Works |  |
| `Task.checkCancellation()` | Works |  |
| `Task.yield()` | Works |  |
| `Task.sleep(nanoseconds:)` | Works |  |
| `withTaskGroup` | Works |  |
| `withThrowingTaskGroup` | Works |  |
| `cancelAll()` and `isCancelled` of a group | Works |  |
| `async let` | Works |  |
| Reading an `async let` without `await` | Rejected, as in Swift |  |
| `await` outside an async function | Rejected, as in Swift |  |
| An `async` closure | Works |  |
| `Task.sleep(for:)` and `Duration` | Not supported |  |
| `Task.detached` | Not supported |  |
| `Task(priority:)` | Not supported |  |
| `Task.currentPriority` | Not supported |  |
| `withDiscardingTaskGroup` | Not supported |  |
| Task-local values | Not supported | `@TaskLocal` is not read. |

## Actors and isolation

| Feature | Status | Note |
| --- | --- | --- |
| `actor` declarations | Works |  |
| Reading an actor's state without `await` | Rejected, as in Swift |  |
| `nonisolated` members | Works |  |
| `@globalActor` declarations | Works |  |
| `isolated` parameters | Not supported | The access is treated as coming from outside the actor. |
| Calling a `@MainActor` function from outside it | Runs; Swift rejects it | `@MainActor` is accepted and nothing is isolated. |
| Capturing a non-`Sendable` class in a task | Runs; Swift rejects it | `Sendable` is not checked. |
| Mutating a captured `var` in a `@Sendable` closure | Runs; Swift rejects it | `@Sendable` captures are not checked. |

## Streams, continuations and executors

| Feature | Status | Note |
| --- | --- | --- |
| `AsyncStream` | Not supported |  |
| `withCheckedContinuation` | Not supported |  |
| An `AsyncSequence` a script declares | Not supported |  |
| `Mutex` and `Atomic` (the Synchronization module) | Not supported |  |
| Custom executors (`SerialExecutor`, `TaskExecutor`) | Not supported |  |

## Language

| Feature | Status | Note |
| --- | --- | --- |
| Generic functions | Works |  |
| Protocols with associated types | Works |  |
| `any P` and `some P` | Works |  |
| Default implementations in protocol extensions | Works |  |
| Enums with payloads and patterns | Works |  |
| Typed throws | Works |  |
| Classes with `override` and `super` | Works |  |
| Extensions with a `where` clause | Works |  |
| Subscripts | Works |  |
| `lazy var` | Works |  |
| Property observers | Works |  |
| Property wrappers | Works |  |
| Result builders | Works |  |
| Custom operators | Works |  |
| `#if os(…)` and `canImport` | Works |  |
| `if` expressions | Works |  |
| `switch` expressions | Not supported | `if` expressions work. |
| Synthesized `Equatable` and `Hashable` | Works |  |
| Key paths used as functions | Works |  |
| Key path subscripts, `x[keyPath: \S.v]` | Not supported |  |
| Regex literals, `/ab/` | Not supported |  |
| Noncopyable types and `consume` | Not supported |  |
| Parameter packs, `each T` | Not supported |  |
| Custom string interpolation | Not supported |  |
| `Codable`: `JSONEncoder` and `JSONDecoder` | Not supported |  |
| Macros a program declares | Not supported |  |

## Host boundary

| Feature | Status | Note |
| --- | --- | --- |
| Importing a package or module at run time | Not supported |  |
| A script's struct or enum passed where Swift wants a real type | Not supported |  |
| Protocols with associated types as values (`some Collection`) | Not supported |  |
| Swift calling a script type's methods; subclassing a Swift class | Not supported |  |

## Execution model

| Feature | Status | Note |
| --- | --- | --- |
| Tasks run in parallel | Not supported | Tasks are threads behind one lock and switch only at waits, so CPU-bound tasks run one at a time. |
| A task spinning on state another task sets | Not supported | It can deadlock, as nothing releases the lock until a wait. |
