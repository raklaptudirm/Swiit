# Async

`$(…)` is a call that can take a while, and the shell can do other things
while it does. Today it can't: the interpreter is one thread, `$(…)` blocks
it, and only programs can run in the background. This is a design for making
`$(…)` a suspension point the way `try` is a throwing point: you write
nothing extra, the language knows, and it can run other work meanwhile.

Nothing here is built. It says what's decided, what isn't, and an order to
build it in. It follows [direction.md](direction.md): Swish is Swift with the
shell as seasoning, so concurrency follows Swift's model, and only the shell
constructs get implicit behavior.

## Where it stands

- **One interpreter thread.** The shell runs on a thread with a large stack
  (`Sources/Swish/main.swift`, `onLargeStack` in `Runtime/Platform/IO.swift`), because
  `evaluate` recurses. There is no other thread that runs Swish code.
- **Global mutable state on the `Shell`:** `scopes`, `stdoutFD` (which
  `capturing` swaps so a command's output lands in a pipe), `callDepth`,
  `lastStatus` and `jobs`. All of it assumes one thing runs at a time.
- **`$(…)` runs its block in-process** with `stdoutFD` pointed at a pipe that
  a reader thread (`OutputCollector`) drains, then waits. It can run Swish
  functions, not only programs.
- **Concurrency is the operating system's:** a foreground pipeline's programs
  run in parallel, and the shell waits with `waitpid`. `async` starts the same
  kind of pipeline and returns it as a `Job`; `startJob` refuses anything
  that isn't a program (*"Swish functions and values can't run in the
  background yet"*). `job.lines()` reads a job's output as it arrives.
- **Interrupts are a flag.** A signal handler sets `interrupted`;
  `checkInterrupt` polls it between steps and a blocked wait is woken by the
  signal itself.
- **Swift calls back into Swish synchronously.** `xs.map { … }` is Swift's
  `map` calling a Swish closure through `shell.call`; a plugin's function is a
  plain Swift function called on the shell's thread.

## What we want

1. **`$(…)` is implicitly awaited.** `let x = $(git status)` reads as it does
   now, and has type `Output`, not a task. Where it waits, other work may run.
2. **Work can run concurrently, by choice.** `async` starts something and
   gives back a handle; `await` joins it. Anything can be started that way: a
   command, a Swish function, a closure, not only a program.
3. **Cancellation reaches everything.** `^C` and `job.cancel()` stop a task
   and what it started: its programs, its own tasks, and what it's waiting on.
4. **Lazy output composes.** A stream of lines (`Flow`) is read where it's
   used, and reading waits where it has to.
5. **No cost where you don't use it.** A script that never says `async` runs
   as it does now, as fast, with the same errors.

Not goals: running Swish code in parallel (programs run in parallel; Swish
code doesn't need to), preemption, or a visible `async` on functions.

## The model

### Tasks and suspension points

A **task** is a line of execution through Swish code, with its own call stack
(its frames and their locals), its own standard output, and a cancellation
flag. The shell's prompt is the first task. Tasks share the global scope.

A task **suspends** only where it waits for something outside itself:

- `$(…)` and a command in the foreground (the process or pipeline finishing),
- `await` (another task finishing),
- reading a `Flow` whose next item isn't there yet,
- reading a line at the prompt, and `sleep`.

Between suspension points a task runs alone. That is the guarantee that
keeps this simple: **no two tasks ever run Swish code at the same instant,
so a variable can't change under you except across a suspension point.** It
is how a single-threaded `async`/`await` behaves, and nothing about the
language needs locks.

A program with one task behaves exactly as today: every wait is just a wait.

### Starting and joining

```swift
let a = async $(slow-query one)        // a Job, running
let b = async $(slow-query two)
let both = (try await a, try await b)  // takes as long as the slower one

async { build(); notify() }            // a closure, in the background: a job in `jobs`
let t = async fetch("x")               // a Swish function, in the background
try await t                            // its value, or what it threw
```

- `async expr` starts a task for `expr` and gives its handle, the `Job` that
  `jobs` lists. This is today's `async`, extended to any expression or block,
  not only a program. A background *program* is a job whose body is the
  pipeline.
- `await job` suspends until it's done and gives its result: the `Output` for
  a command job, the value for Swish code. `try await` throws what the task
  threw, as `try await` on a failed command does now.
- **A task belongs to the scope that starts it.** This is one rule, for
  functions and for the prompt alike. The prompt isn't a series of separate
  scopes: it is one scope, paused between lines, that closes when the shell
  exits, so `async make` at the prompt is a child of that scope and outlives
  the line, which is what `&` means in a shell. In a function it's a child of
  the call. When a scope closes, a child still running is cancelled and
  awaited, as Swift does for `async let`; a throw cancels the scope's
  children the same way. There's no separate detached form to learn.

### Types and effects

`$(…)` is `Output`; `async $(…)` is `Job`. What a function waits on is an
**effect** in its type, as `throws` is, and function types gain `async`
(`(Int) async -> Int`), with a sync function converting to an async one.

- **User-written effects follow Swift.** An `async` function is declared
  `async`, calling it needs `await`, and `await` needs an async context.
- **Effects that come only from shell constructs are inferred.** `$(…)` is a
  wait (and, with `try`, a throw), so a function whose only waits are `$(…)`
  is async without saying so, and so is whatever calls it with no `await` of
  its own. This is the one place Swish departs from Swift, and only because
  the effect comes from a shell construct.
- **Higher-order functions are `reasync`.** A Swish function that calls a
  closure parameter is async at a call site exactly when that closure is. The
  same tree is run by the sync or the async evaluator as the call needs, so
  nothing is written twice.
- **Pure code stays sync.** A function with no wait in it, or in anything it
  calls, runs on the sync evaluator at full speed.
- **Closures a Swift function can't await** are a static error: passing a
  closure that waits to a Swift function with no async overload is rejected
  with a message, not left to hang (see the spike's deadlock).

### Output, and `$(…)` inside a task

`stdoutFD` stops being a field of the `Shell` and becomes the current task's,
so `$(…)` in one task redirects that task's output and nobody else's. Today's
`capturing` is the same operation done to one task.

### Failure and cancellation

- A task that throws ends with that error, kept on its job; whoever `await`s
  it gets it. A detached job that fails says so in `jobs`, as now.
- `^C` cancels the **foreground task and everything under it**: it sends the
  signal to the foreground process group, as now, and sets the cancellation
  flag of the task and its children. A task notices the flag at the next
  suspension point and at the `checkInterrupt` polls that already exist.
  Cancelling ends a wait early (the process dies, the `Flow` read returns) and
  raises `Interrupted`, which unwinds like any error and runs `defer`s.
- `job.cancel()` does the same for one job and what it started.
- A cancelled job's state is `cancelled`, which it already is.

### Streams

`Flow` stays a pull stream. Reading it from a task is a suspension point where
it has to wait, as `job.lines()` already is. Nothing here changes `$(…)`'s
type: a finished `Output` stays finished.

One optimization falls out and is left for later: a `$(…)` used only as the
sequence of a `for` or the head of a pipeline could stream, since the checker
can see nothing else reads it. It changes when output appears and when a
failure is seen, so it would be opt-in or documented before it's done.

## Ways to build it

### A. Swift concurrency throughout

`evaluate` and everything under it become `async throws`; a task is a Swift
`Task`; `$(…)` awaits its pipeline; cancellation is `Task.cancel()`; `Flow`
becomes an `AsyncSequence`.

For: structured concurrency and cancellation come with the runtime; `async
let` is literally Swift's; no large-stack thread (async frames live on the
heap); the standard library's lazy `AsyncSequence` operators are available.

Against:

- **Swift calls Swish synchronously.** `Array.map` can't await. Bridged
  closures would need to block a thread to wait on an async `evaluate`, which
  deadlocks on the cooperative pool unless Swish code runs on an executor of
  its own. That executor has to be built either way, so most of A's runtime
  benefit goes.
- **The checker's `Sendable` bill.** `Value`, `Function`, `Scope` and `Shell`
  would need isolation or `@unchecked Sendable` with an argument for each.
- **Cost on every node.** A tree-walker pays an async call per expression.
  This is unmeasured; it needs a spike before anyone claims a number.
- Every call site changes (about 3,900 lines under `Interpreter/` and
  `Execution/`), in one go, since async can't be adopted halfway.

### B. Tasks on threads, with one lock

Each task runs the unchanged synchronous interpreter on a thread of its own.
A **global interpreter lock** admits one task at a time. A task releases it
only when it suspends (a wait on a process, a task, a stream, or input), and
takes it back when it's ready. Nothing else changes: Swift calling Swish
synchronously is a plain call on the task's thread; a `$(…)` inside a closure
inside `Array.map` waits, releasing the lock, and carries on.

For: the semantics above exactly (one task at a time, switching only at
suspension points) with the interpreter, the bridge and plugins as they are;
deep recursion still has its large stack, per task; small, and each phase is
testable on its own.

Against: it's not Swift's `async`, so `Flow` doesn't become an
`AsyncSequence` by itself (an adapter is small); a thread per task is heavy
for thousands of tasks, which a shell doesn't have; the lock has to be right
(held across all Swish code, released at every suspension, never across a
callback into Swift that waits).

### A, with inferred effects

A's trouble was the synchronous callback: Swift's `map` can't await. Three
things together remove it:

1. **Async overloads of the closure-taking standard library functions,**
   written as extensions in `SwishStandardLibrary` (`map`, `filter`,
   `compactMap`, `reduce`, `sorted(by:)`, `contains(where:)`, `first(where:)`,
   `forEach`, `prefix(while:)`, and the rest: about forty, each a short loop).
   Swift allows overloads that differ only in `async`, and the generator
   already bridges extensions, once it reads `async` declarations.
2. **Effects in the checker** (above). A closure that doesn't wait contains no
   async feature, so it goes to Swift's ordinary sync `map` with no bridge. A
   closure that waits selects the async overload. A function with no async
   overload and a waiting closure is a static error.
3. **Two evaluators over one tree,** the async one generated from the sync
   source (or the reverse) by a macro in the style of `@Reasync`, with only
   the leaf waits written twice. Inside a callback the sync one runs on the
   current thread, so nothing waits on the pool.

That keeps macOS 14 (no `TaskExecutor`), has no thread per nested callback and
no deadlock, and leaves pure code at full speed. What remains: effects in
function types, the redefinition rule (changing a function from sync to async
under callers that already exist is rejected), a conservative rule for values
of unknown type, and the async runtime. One shell-specific point: `$(…)` must
count as a wait, or a background function made of `$(…)` calls would block the
interpreter and freeze the prompt.

### Recommendation

Given [direction.md](direction.md), **A with inferred effects is the
destination.** Swish's concurrency should be Swift's (tasks, `async let`,
task groups, `for await`, `AsyncSequence`, async library calls bridged as
they are, a compiled plugin's `async` functions awaited directly), and B
would reimplement that on a lock. B stays as the fallback if the effect
system proves harder than it looks. The first two steps of the plan are
shared by both, so they come first whichever is chosen.

## Spike results

A small tree-walking evaluator shaped like Swish's (a `Value` enum, chained
environments of named bindings, functions called by name), written twice over
one tree, sync and `async throws`, built in release on Swift 6.2, 8 cores.

| | sync | async |
|---|---|---|
| `fib(27)`, about 1.2 million calls | 120–130 ms | 184 ms on the default executor (1.5×); 240 ms on a custom queue executor (1.9×) |
| a call 1,000,000 deep | 264 ms on a 1 GB stack | 449 ms |
| a call 10,000,000 deep | overflowed the 1 GB stack | finished, 5.5 s, about 2.5 GB resident |

- **Cost.** An async call that doesn't suspend is cheap: about 1.5× on a
  micro-benchmark that is nothing but calls. A real evaluator spends time on
  lookups, conversions and the bridge too, so the share is lower; it isn't
  measured here.
- **Depth is a gain.** Async frames live on the heap, so the large-stack
  thread and its fixed limit go away; memory is what bounds a recursion.
- **The synchronous callback is the problem, and it's real.** `[1].map { … }`
  calling a closure that must wait on the async evaluator, blocking its
  thread on a `Task` of the default pool, **deadlocks at a nesting depth equal
  to the core count** (8 here): every pool thread is blocked waiting for one
  that doesn't exist. Nothing warns; the shell just stops.
- **It can be avoided, at a price.** Running each nested evaluation on a
  `TaskExecutor` of its own (a queue per level) worked to a depth of 200. It
  needs `TaskExecutor`, which is **macOS 15 and later; Swish's deployment
  target is macOS 14**, and it spends a thread per level of nesting. The
  other way out, a synchronous twin of the evaluator for use inside
  callbacks, doubles the evaluator.

So A is affordable in speed and better in depth, and costs: a deployment
target raised a version (or a duplicated evaluator), a thread per nested
callback, and the rewrite of everything under `Interpreter/` and `Execution/`
with its `Sendable` pass. B has none of these. The recommendation stands.

## Plan

Each step is its own change with its own tests, and each leaves the shell
working.

(The `SwishHost` seam of [embedding.md](embedding.md) comes first: it is where
the task context's output and the `suspend` function sit.)

1. **Make the task explicit, change nothing visible.** Split the `Shell`'s
   per-task state (`stdoutFD`, the call stack and `callDepth`, the
   cancellation flag, the current job) into a `TaskContext`, leaving the
   global scope, the `jobs` table and configuration where they are. The
   prompt runs in the one context. All tests pass unchanged.
2. **Suspension points name themselves.** Every wait goes through one
   function (`suspend { … }`) instead of calling `waitpid`, `read` or a
   semaphore directly: foreground commands, `$(…)`, `await`, a `Flow` read,
   the line editor, `sleep`. Still one task, so it just calls the closure.
   This is the seam the async evaluator's `await`s later replace.
3. **Effects in the checker, with no runtime change.** (The inferred part is
   the rewrite pass of [desugaring.md](desugaring.md), "Effects": shell
   constructs become `await`s and their functions `async`, and the checker
   then applies only Swift's rules.) `async` in function
   types and declarations; Swift's rules for explicit `async` and `await`;
   `$(…)` as an inferred wait; `reasync` for closure parameters; the
   redefinition rule. The interpreter still blocks at every wait, so only the
   checker's answers are new, and they are tested as errors and inferred
   types.
4. **The generator reads `async`.** `BridgedMember` gains `isAsync`, native
   bodies an async form, glue `try await`; the standard library's async
   overloads are written and bridged; a waiting closure with no async overload
   is the static error.
5. **The async evaluator and tasks.** The async evaluator, generated from the
   sync one; Swish tasks as Swift `Task`s on one serial executor, so Swish code
   still runs one task at a time; `async` and `await` for any expression;
   async versions of the leaf waits (process exit, `$(…)`, `Flow` reads,
   `await` on a job, `sleep`).
6. **Cancellation and scopes.** `^C` and `cancel()` cancel a task tree (Swift's
   cancellation, plus the signal to the foreground process group); a scope
   closing cancels and awaits its children; the task cap.
7. **Per-task output and streams.** `$(…)` redirects the task's own output;
   `Flow` becomes readable as an `AsyncSequence`.

Tests that must hold by the end: two `async $(sleep 1)` awaited together take
about one second; `async f()` runs a Swish function while the prompt carries
on; `^C` stops a task and the programs it started; a variable changed by one
task is seen by another only after a suspension; a waiting closure passed to
`map` works, and to a function with no async form is an error; a script
without waits runs the same suite, at the same speed.

## Risks

- **Yielding across a native call.** Lua forbids a yield across a C call
  unless the call supplies a continuation (`lua_callk`, `lua_yieldk`). A
  registered closure that calls back into the interpreter is the same case
  here: under the cooperative design (A) it blocks its task's thread or must
  be written as async. Say so in the registration API, and give such closures
  an async form rather than a continuation.
- **The effect system is the new weight.** Effects in function types, overload
  choice by a closure's effect, `reasync` at call sites, and inference through
  shell constructs touch the checker in many places. Step 3 is its own change
  with no runtime effect for that reason: it can be tested, and rejected or
  reshaped, before anything depends on it.
- **Redefinition at the prompt.** A function changed from sync to async under
  callers that already exist. Written as a clear error; the alternative,
  re-checking the callers, is open.
- **Values whose effect isn't known.** Untyped values from builtins and
  plugins. They need a conservative rule or the same static error.
- **One task at a time on one serial executor.** A sync function that blocks
  (a plugin's, a native call) stalls every task for as long as it does, as it
  blocks the shell today. Waits the interpreter owns (`$(…)`, process exit,
  `Flow`, `sleep`) are async, so they don't. A plugin can be given an async
  entry point later.
- **Two evaluators.** One is generated from the other; the leaf waits are
  written twice. A macro dependency, or hand-kept copies if it proves too
  limited (the spike found it works syntactically and leaves invalid output to
  the compiler).
- **Cancelling a wait.** A task waiting on a process or a stream is woken by
  the cancellation; each async wait needs its cancel path written and tested.
- **State that isn't per task yet.** `lastStatus` and the current job are the
  shell's today and become the task's; directory and environment are the
  process's and stay global.
- **If B is needed.** The lock invariants (every wait is `suspend`; Swish code
  runs only under the lock) and `@unchecked Sendable` on the interpreter's
  types, argued once next to the lock.

## Decided

- **One lifetime rule.** A task belongs to the scope that starts it; the
  prompt is one scope, open until the shell exits (see "Starting and
  joining").
- **Cancellation unwinds like an error** and runs `defer`s.
- **The number of tasks is capped,** with a clear error when it's reached; a
  generous default (256), configurable.
- **A, with inferred effects, is the destination.** It follows from
  [direction.md](direction.md); B is the fallback (see "Recommendation"). The
  spike below measured A's costs.
- **Effects follow Swift for user-written code,** and are inferred only where
  they come from shell constructs.

## Open questions

- **What does a closing scope do to a child still running, at a script's
  end?** Written as cancel and await, as in Swift. A shell script is used to
  background jobs outliving it, so a script that wants one to finish writes
  `await`; if that's too surprising, a script's end could await instead of
  cancel. The session's end, an interactive shell exiting, hangs up its jobs
  as shells do.
- **What does `lastStatus` mean after `await`?** Today an awaited job's
  status is the statement's. It should stay so, and it's the awaiting task's.
