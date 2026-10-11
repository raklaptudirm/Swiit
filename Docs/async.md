# Async

`$(…)` is a call that can take a while, and the shell can do other things
while it does. Today it can't: the interpreter is one thread, `$(…)` blocks
it, and only programs can run in the background. This is a design for making
`$(…)` a suspension point the way `try` is a throwing point: you write
nothing extra, the language knows, and it can run other work meanwhile.

Steps 1 to 3 of the plan are built; the rest says what's decided, what
isn't, and an order to build it in. It follows [direction.md](direction.md)
and the vision's parity with the compiler: concurrency follows Swift's model,
and the shell's constructs are blocking calls, not effects.

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

1. **`$(…)` blocks, and `async $(…)` doesn't.** `let x = $(git status)` reads
   as it does now: it waits for the program and has type `Output`, and the
   function it's in stays an ordinary function. `async $(…)` runs it in the
   background and gives a `Job`. While one task waits, other tasks run.
2. **Work can run concurrently, by choice.** `async` starts something and
   gives back a handle; `await` joins it. Anything can be started that way: a
   command, a Swish function, a closure, not only a program.
3. **Cancellation reaches everything.** `^C` and `job.cancel()` stop a task
   and what it started: its programs, its own tasks, and what it's waiting on.
4. **Lazy output composes.** A stream of lines (`Flow`) is read where it's
   used, and reading waits where it has to.
5. **No cost where you don't use it.** A script that never says `async` runs
   as it does now, as fast, with the same errors.

Not goals, for now: running Swish code in parallel (programs run in
parallel; Swish code doesn't need to), or preemption.

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

`$(…)` is `Output`; `async $(…)` is `Job`. Function types gain Swift's `async`
(`(Int) async -> Int`), and only Swift's.

- **Effects follow Swift.** An `async` function is declared `async`, calling
  it needs `await`, and `await` needs an async context: the top level, an
  `async` function, or a closure, which becomes async.
- **The shell's waits are blocking calls, not effects.** `$(…)`, a command,
  and `await job` block their own task until they're done, as
  `Process.waitUntilExit()` does in compiled Swift. A function made of them is
  an ordinary sync function, called and passed like any other, so nothing is
  inferred and nothing departs from Swift.
- **Concurrency is chosen with `async`.** `async $(…)` and `async cmd` start
  programs in the background, and `async f()` and `async { … }` Swish code;
  each gives a `Job`, which `await` joins by blocking.

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

### Decision: B, with `$(…)` blocking

Earlier this recommended A with inferred effects, with B as the fallback.
Making `$(…)` a blocking call, and `async $(…)` the way to run it in the
background, changes the balance, and **B is the way it's built**:

- A's inferred effects existed so that a background function made of `$(…)`
  calls wouldn't freeze the prompt. Under B a blocking wait releases the
  lock, so it blocks only its own task, and there is nothing to infer: the
  checker applies Swift's rules and nothing else.
- B keeps one evaluator, the bridge and plugins as they are, deep recursion
  on a large stack per task, and macOS 14. Swift calling a Swish closure is a
  plain call on the task's thread, so the spike's deadlock can't happen, and
  no async overloads of `map` and the rest are needed.
- The semantics are still Swift's (see "Against the compiler"): tasks, `async
  let`, task groups, `for await`, cooperative cancellation and task-local
  values are the interpreter's own, built on the task threads; a Swift
  `async` API is bridged as a wait (the interpreter starts the Swift task and
  waits for it in `suspend`, which a task thread may do, as it isn't the
  cooperative pool's).

### Against the compiler

[vision.typ](../vision.typ) asks for parity with the compiler, speed aside.
One task at a time is a correct execution of a Swift program: Swift 6 rules
out data races with `Sendable` and actor isolation, so a program the
compiler accepts can't tell tasks taking turns from tasks in parallel, except
by speed. Actor isolation holds trivially, and an actor's reentrancy at an
`await` is kept, as other tasks run exactly at waits. What parity still needs:

1. **No parallel speed.** CPU-bound tasks run one at a time; the vision
   allows that. The lock can be made finer later, because Swift's own
   guarantees are what make that safe.
2. **`Sendable` and actor isolation in the checker.** Under the lock, Swiit
   would accept and run without a race programs the compiler rejects. That
   is checker work, independent of the runtime.
3. **Blocking bridged calls release the lock.** Bridged Swift code that
   blocks (a `Mutex`, a semaphore, synchronous I/O) while holding the lock can
   wait on a task that can't run. Every such call goes through `suspend`, and
   the generator can mark them.
4. **Swift's `async` APIs, both ways.** Called from Swish, as above. Called
   by Swift with a Swish closure as an `async` closure, the closure is handed
   to an interpreter thread and its result returned through a continuation,
   so no pool thread waits for the lock.
5. **Switching only at waits** can deadlock code Swift would run, like a task
   spinning on an atomic another sets. Releasing the lock at atomics and
   `Task.yield()`, or a time slice, are the fixes, when a program needs them.

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
with its `Sendable` pass. B has none of these, which is part of why it was
chosen (see "Decision").

## Plan

Each step is its own change with its own tests, and each leaves the shell
working.

(The `SwishHost` seam of [embedding.md](embedding.md) comes first: it is where
the task context's output and the `suspend` function sit.)

1. **Make the task explicit, change nothing visible.** Split the `Shell`'s
   per-task state (`stdoutFD`, the call stack and `callDepth`, the
   cancellation flag, the current job) into a `TaskContext`, leaving the
   global scope, the `jobs` table and configuration where they are. The
   prompt runs in the one context. All tests pass unchanged. *Done:* the core's
   `TaskContext` holds a task's scopes (the global two shared, as `Scope`s
   are references), `callDepth`, `returnTypes`, the per-item error count and
   the cancellation flag, and a slot for what the host keeps per task; the
   interpreter's properties of those names forward to the current task's. The
   shell's `ShellTask`, in that slot, holds `stdoutFD`, `stderrFD` and the
   status. (A call-heavy loop runs about 5% slower, from the extra hop.)
2. **Suspension points name themselves.** Every wait goes through one
   function (`suspend { … }`) instead of calling `waitpid`, `read` or a
   semaphore directly: foreground commands, `$(…)`, `await`, a `Flow` read,
   the line editor, `sleep`. Still one task, so it just calls the closure.
   This is the seam the async evaluator's `await`s later replace. *Done:*
   `Interpreter.suspend { … }`, through which the shell waits for a
   foreground job (and so `await` and `sleep`), a `$(…)`'s output, a job's
   lines, a program's output read into an in-process stage, and a line of
   input at the prompt or from a script. The library's `readLine()` can't reach
   the interpreter from its module, and waits directly for now.
3. **Effects in the checker, with no runtime change.** *Done:* function
   types and declarations carry an `Effect` (`sync` or `async`), and both front
   ends read `async`. A call to an `async` function needs `await`; `await`
   needs an async context (the top level, an `async` function, or a closure,
   which becomes async); an `async` function isn't passed where a sync one is
   wanted; an `await` with nothing async in it is an error (Swift only warns).
   A function becoming `async` at the prompt is refused while functions
   declared earlier call it without `await`, naming them. (A first version also
   inferred an "implicitly async" effect from the shell's waits; it went when
   `$(…)` became a blocking call.)
4. **The interpreter lock, and tasks as threads.** One lock, held by the task
   running Swish code; `suspend` releases it around the wait and makes the
   task current again after. Tasks run on large-stack threads the host makes
   (`SwishHost`, so an embedder can bring its own), up to the cap. The core's
   task API in Swift's terms (`Task { … }`, `.value`, `.cancel()`, then `async
   let`), and the shell's `async f()` and `async { … }` rewritten to it; the
   shell's `Job` wraps processes or a core task, so `jobs`, `await job` and
   `job.cancel()` work the same for both. Switching only at waits, for now.
5. **Cancellation and scopes.** `^C` and `cancel()` set the task's flag
   (checked at the interrupt checks) and signal the programs it started; every
   wait can be woken; a scope closing cancels and waits for the tasks it
   started.
6. **Output and the terminal.** A background Swish task's output is kept on
   its job, as `async $(…)`'s is, unless it prints; a background task reading
   the terminal waits until it's brought forward with `await`, as a program
   is stopped; plugins get a "wait without the lock" helper in SwishKit.
7. **Swift's `async`, bridged.** The generator reads `async`; a Swift `async`
   call from Swish is a wait in `suspend`, and a Swish closure Swift calls as
   `async` runs on an interpreter thread; `Flow` readable as an
   `AsyncSequence`, and `for await`.

Tests that must hold by the end: two `async $(sleep 1)` awaited together take
about one second; `async f()` runs a Swish function while the prompt carries
on; `^C` stops a task and the programs it started; a variable changed by one
task is seen by another only after a wait; a closure running `$(…)` passed to
`map` works while other tasks run; a script without `async` runs the same
suite, at the same speed.

## Risks

- **The lock's invariants.** Swish code runs only under the lock; every wait
  is a `suspend`; the lock is never held across a callback into Swift that
  waits. Each is argued once, next to the lock, with `@unchecked Sendable` on
  the interpreter's types.
- **A blocking call that isn't a `suspend`.** A plugin's or a bridged Swift
  function that blocks holding the lock stalls every task, as it blocks the
  shell today. The generator marks blocking bridged calls; plugins get the
  helper (step 6).
- **A CPU-bound background task** holds the lock until it waits, freezing the
  prompt. ^C still reaches the foreground through its signal. A time slice
  is the fix if it proves a problem; it weakens "state changes only across
  waits" to "no data races".
- **A thread per task.** A large stack each, reserved rather than used; the
  cap bounds them.
- **Cancelling a wait.** A task waiting on a process, a job, a stream or input
  is woken by the cancellation; each wait needs its cancel path written and
  tested.
- **State that isn't per task yet.** The current job becomes the task's;
  directory and environment are the process's and stay global.

## Decided

- **One lifetime rule.** A task belongs to the scope that starts it; the
  prompt is one scope, open until the shell exits (see "Starting and
  joining").
- **Cancellation unwinds like an error** and runs `defer`s.
- **The number of tasks is capped,** with a clear error when it's reached; a
  generous default (256), configurable.
- **B, tasks on threads behind one lock, switching only at waits** (see
  "Decision"); the parity work it leaves is listed in "Against the compiler".
- **`$(…)`, commands and `await job` are blocking calls,** not effects; only
  Swift's `async` is an effect, with Swift's rules.

## Open questions

- **What does a closing scope do to a child still running, at a script's
  end?** Written as cancel and await, as in Swift. A shell script is used to
  background jobs outliving it, so a script that wants one to finish writes
  `await`; if that's too surprising, a script's end could await instead of
  cancel. The session's end, an interactive shell exiting, hangs up its jobs
  as shells do.
- **What does `lastStatus` mean after `await`?** Today an awaited job's
  status is the statement's. It should stay so, and it's the awaiting task's.
