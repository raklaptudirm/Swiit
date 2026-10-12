# Agenda

What is next for Swiit, most important first. A line leaves when it is done;
the reasons stay in the notes it points to.

## Now: finishing the split

1. **Swish builds on this repository.** Until it does, there are two copies
   of the interpreter and they drift. SwiitKit is a nested package, which a
   URL dependency can't reach, so first decide how it ships: a repository of
   its own, or a dynamic product of this package (the dylib is what lets a
   host and its plug-ins share one copy). Then Swish pins an exact version
   and `Packages/Swiit` and `Packages/SwiitKit` leave it ([extraction.md](extraction.md), stage 7).
2. **Tag 0.1.0, and the versioning rule.** A minor release may break the host
   API until 1.0; the shell pins exactly and moves up on purpose (stage 8).
3. **The bridge-currency check in this repository's CI.** The generator is
   run from the shell's `run bridge`; it needs to run by itself, so a stale
   bridge fails here and not only in Swish.

## Next: the language

4. **Swift parity gaps:** task groups (they need generics and metatypes),
   parameter attribute spellings, and parameter validation beyond what the
   tests cover.
5. **Diagnostics point at the source.** Keep SwiftSyntax's source ranges on
   our nodes, so errors, highlighting and tools can refer to the original
   tree without it being the tree we run ([frontend.md](frontend.md)).
6. **Finish the swift-syntax review:** confirm the two suspicions about
   SwiftOperators (`DefaultPrecedence`, the ignored error handler) and report
   upstream what holds.

## Later

7. **A smaller plug-in surface.** `Layer` is the tree and the checker's
   hooks. A layer could build nodes through a few constructors instead.
   Worth it if the contract proves hard to use from outside.
8. **The evaluator's speed.** It walks a tree and looks variables up by name.
   Profile first (a hot loop, deep recursion, a pipeline over many lines).
   If it matters, in this order, stopping when it is fast enough: variables
   as slots resolved by the checker; the checked tree compiled to closures;
   bytecode only after those. Using SwiftSyntax's tree for evaluation was
   considered and set aside: the shell's nodes live in our tree until
   desugaring, the checker's results are written into it, and it is the
   evaluator's hot path.
