# Handling a failed run

`evaluate` throws one error type, ``Diagnostic``. It holds a message, an optional range (SwiftSyntax's `SourceRange`) and a `kind`.

## Check the diagnostic's kind

``Diagnostic/kind`` is one of these cases:

- `syntax(isIncomplete:)`: the source doesn't parse. `isIncomplete` is `true` when the source ends too soon and another line could finish it,
  which is how a prompt knows to keep reading.
- `type`: the checker rejected the program before any statement ran.
- `runtime(Failure)`: a statement failed in a way a script's `catch` can see.
- `fatal(Failure)`: a failure that `catch` and `try?` don't see, such as a failed `try!` or a host function ending the script. `defer` blocks
  still run.
- `limit`: a ``Interpreter/Limits`` value was reached.
- `cancelled`: ``Interpreter/cancel()`` or `shouldStop` stopped the run.

A ``Diagnostic/Failure`` holds what `catch` binds (the message, or a ``Value`` the host built), its origin (`language`, `host`, or `hostError`
with the host's own `Error`), the functions it unwound through, and where to print it.

## Print it with its source line

``Diagnostic/rendered(in:path:color:)`` returns the message followed by the line of source with the failing place marked by `^`, in ANSI color if
`color` is `true`. ``Diagnostic/rendered(in:path:style:)`` takes a ``Diagnostic/Style`` that colors the source line, the frame and the mark, so
a host can highlight that line the way it highlights its own source. `in:` is the source text the ranges refer to.

## Throw one from a host function

Throw ``Diagnostic/runtime(_:thrown:cause:)`` for a failure a script can catch, or ``Diagnostic/fatal(_:cause:)`` to end the script. Pass your
own `Error` as `cause` to read it back later from the failure's origin, for example a command's exit status.
