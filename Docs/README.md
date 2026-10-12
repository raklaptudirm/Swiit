# Swiit's design notes

The interpreter's own design, which goes where it goes. Links to the shell's
notes (`../../../Docs/Design/…`) are the first client's, and become prose or
links to its repository at the move (extraction stage 7).

- [embedding.md](embedding.md): the public API, and what stays SPI.
- [frontend.md](frontend.md): SwiftSyntax as the front end, the plug-in contract, and the retired hand parser.
- [types.md](types.md): static types, checked before anything runs.
- [callables.md](callables.md): one callable for functions and commands.
- [foundations.md](foundations.md): every function, method and type as a Swift one.
- [swift-interop.md](swift-interop.md): bridging Swift's libraries, and generated twins.
- [async.md](async.md): tasks, suspension points and effects. The shell's `$(…)` and jobs are its first client; they stay in this note until they are lifted out.
- [boundaries.md](boundaries.md): the line between the core and a layer, and the ledger that keeps it.
