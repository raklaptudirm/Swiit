# What a Swift body can rely on

The promises Swiit makes to the Swift code it runs on a script's behalf.

## Overview

A script runs inside the interpreter, and sometimes the interpreter runs Swift: the body of a ``HostSymbol`` (a function, or a member of a
type written with ``HostType/Builder``), a closure given to ``Interpreter/register(_:labels:throwing:_:)-f2lx``, or a body that
``Interpreter/declare(_:bodies:)`` pairs with a declaration. This article is what such a body may assume. It is a contract, not a description
of how the evaluator happens to work today: an evaluator that replaces the present one keeps every promise here, or the change says it does
not.

The promises are written as tests (`NativeContractTests`), one for each, so that a replacement evaluator is checked by running them.

## How a body is called

A body is called synchronously, on the thread that runs the script's task, once for each call the script makes, and the script's next step
waits for it. Its arguments are the call's, in the order the parameters were declared, with the defaults of the ones the call left out
filled in. A body of ``Interpreter/declare(_:bodies:)`` gets them by parameter name instead.

Checking a program (``Interpreter/check(_:)``) runs no body.

A body gets values, not variables. A list or a struct it is given is a copy: what the body does with it does not change the script's own.

## One at a time

Bodies of different tasks never run at once. The interpreter runs one task at a time, and a body holds it for as long as it runs. A body
that blocks (a read, a child process, a network call) says so by wrapping the wait in ``Interpreter/whileWaiting(_:)``, which lets other
tasks run meanwhile. What is inside the wait must not touch the interpreter or any value another task could change.

Which thread a body runs on is not promised: two calls of one body may run on different threads, as each task has a thread of its own. A body
that needs one thread (a framework that does) has to hand its work to it.

## Calling back into the script

A body may call the interpreter that is running it: ``Interpreter/call(_:with:)`` to run a function value it was given,
``Interpreter/evaluate(_:limits:onValue:onError:completion:)-670lm`` to run source, and the other lookups on ``Interpreter``. What the script
does through those calls (a variable it changes) is there when the body returns. A script function that calls a body that calls a script
function can go on as deep as ``Interpreter/Limits/maxCallDepth`` allows.

A body of a type's member cannot hold an interpreter, because the type is shared by every interpreter in
the process. Inside any body, ``Interpreter/running`` is the interpreter that called it, and the same calls are made on it. Outside a body, on
a thread that runs no script code, it is nil.

## When a body fails

Any error a body throws is a script error that a `catch` can catch. A plain Swift error becomes one whose message begins with the name of the
function or member; a ``Diagnostic`` a body throws keeps its message and the value `catch` binds. A body that can throw says
`isThrowing: true`, so that scripts write `try` where they call it.

A failure made with ``Diagnostic/fatal(_:cause:)`` is not caught by the script: its `defer`s run, and it ends the run with the diagnostic.
So do cancelling the run and reaching a limit.

## Stopping

The interpreter counts steps and checks for a stop, a cancel, and the limits, between the steps it takes itself. A body that loops for long
calls ``Interpreter/checkForStop()`` as it goes, or a limit or a cancel waits for it to end.

## A body that changes its receiver

A mutating member of a type is given the value it changes as `inout`, changes it in place and gives back its result. If it throws, the value is
as the body had changed it by then, as in Swift. A body that holds the contents of a collection while it changes them sets the value aside first
(`receiver = .nothing`), or the collection is copied whole on every call. A property a script assigns is different: its setter is given the value and
gives it back changed.

## What is registered, and for how long

A function registered on an interpreter, or declared with ``Interpreter/declare(_:bodies:)``, belongs to that interpreter. The members of a type
written with ``HostType/Builder`` belong to the process: they are registered by the type's name and shared by every interpreter, so such a
body does not capture one interpreter. It finds the interpreter that is calling it by being handed the receiver's value, not by holding one.
