# Agenda

What is next for Swiit, most important first. A line leaves when it is done;
the reasons stay in the notes it points to.

## Now: finishing the split

1. **SwiitKit in a repository of its own.** It is nested here, so Swish
   reaches it by a path beside this checkout and can't pin it by URL. It can't
   be a product of this package: SwiftPM then links a second copy into the
   host, and a plug-in sees two SwiitKits (tried 2026-10-12). Once it has its
   own repository, Swish pins both by version ([extraction.md](extraction.md), stage 7).
2. **The versioning rule** (stage 8): a minor release may break the host API
   until 1.0; the shell pins exactly and moves up on purpose. 0.1.0 is tagged.

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
