# Swiit in a repository of its own

Swiit (`Packages/Swiit`) is meant to be an embeddable Swift interpreter that
Swish is one client of (vision.typ, boundaries.md). This note says whether it
should move to its own repository, and how to get it there.

## Should it

Yes, but not yet. A repository of its own is what being an interpreter for
anyone, not just the shell's engine, looks like: its own issues, releases,
CI and docs, a version a host can pin, and no way for the shell to reach in
without anyone noticing. The boundary work (an empty ledger, `ShellLayer`
gone, the syntax plugin, `statementFinished`, `inputTurn`) was the hard part,
and it's done.

What isn't done is the part a separate repository makes expensive to change:

- **The surface is SPI.** About 850 core declarations are
  `@_spi(Shell) public`, and 44 shell files import with `@_spi(Shell)`. Inside
  one repository that's a cheap way to move fast; across two it's a public
  API with no promises, and every change is a coordinated release in both.
- **The shell's syntax plugin stands on the hand parser.** `ShellSyntax` and
  `Parser+Commands` extend the core's `Parser`, and the SwiftSyntax front end
  drives that parser for the shell's lines (`Lowering.cursor(at:)`). The
  parser's internals are part of the contract.
- **The names cross over.** The core reports errors as `swish:`, depends on
  `SwishKit` and ships `SwishStandardLibrary`, and lends hosts a
  `ShellContext`.

Moving now would freeze all three in their current shape. Moving after
settling them costs little more than moving now, and the history comes along
either way.

## The plan

Each stage is useful on its own, inside this repository; the move is the
last stage, and mechanical by then.

1. **Count the SPI and stop it growing.** A test like the boundary ledger
   lists the `@_spi(Shell)` declarations the shell uses
   (`spi-surface.txt`); a new one fails the test until it's added on purpose.
   The list only shrinks from then on.
2. **Design the host API.** What the shell uses, sorted into what any host
   needs (made `public` and documented in embedding.md: tasks and the lock,
   `SwishHost`, `statementFinished`, `inputTurn`, `owner`, registering object
   members, installing libraries) and what's the shell's habit (moved into
   the shell, or behind a narrower call). An `@_spi(Swiit)` stays only for
   things the core's own modules (`SwiitSwiftSyntax`, the bridge generator)
   share. Done when the shell imports Swiit without `@_spi`.
3. **A syntax-plugin contract without the parser's internals.** Either the
   hand parser retires and the plugin works on SwiftSyntax tokens (frontend.md's
   end state), or `SyntaxPlugin` gets a small public cursor (peek, take, spans,
   recover) that the hand parser and the lowering both implement. The second
   is cheaper and doesn't wait on retiring the parser, so it comes first.
4. **Names.**
   - Error reports take their prefix from the host (`SwishHost.name`, `swish`
     in the shell, `swiit` by default).
   - `SwishStandardLibrary` becomes `SwiitStandardLibrary`.
   - `ShellContext` becomes `HostContext`.
   - SwishKit: the value model and the plugin ABI are the interpreter's, so
     it moves with Swiit as `SwiitKit`. A plugin compiled against it works in
     any host. The shell keeps a `SwishKit` re-export, or plugins move over
     with a deprecation period.
   - Check that "Swiit" is free as a GitHub organization or repository name
     and on the Swift Package Index before anything is published.
5. **Stand-alone build and CI, still in this repository.**
   - `swift test --package-path Packages/Swiit` already runs alone.
   - Its CI job also builds and tests with no path outside `Packages/` (no
     `../SwishKit` once SwishKit lives inside it). It runs the bridge
     generator check against `Packages/Swiit/Bridges` only.
   - The shell's bridges and manifests stay with the shell.
6. **Docs split.**
   - These go with Swiit: embedding.md, frontend.md, types.md, callables.md,
     swift-interop.md, foundations.md, the core parts of async.md and
     boundaries.md, and the interpreter half of vision.typ.
   - These stay: desugaring.md, pipeline.md, plugins.md (pointing at Swiit's
     plugin ABI) and syntax.md.
7. **The move.**
   - Copy the history out with
     `git filter-repo --subdirectory-filter Packages/Swiit` (plus the moved
     SwishKit and docs paths, with `--path` and `--path-rename`) into the new
     repository.
   - Tag `0.1.0` there.
   - Here, replace `.package(path: "Packages/Swiit")` with
     `.package(url: …, exact: "0.1.0")` and delete the directory.
   - A local override (`swift package edit Swiit`, or a path dependency on a
     branch) is how both get changed together during development.
8. **Versioning.**
   - Semantic versions from `0.x`: a minor release may break the host API
     until `1.0`.
   - The shell pins an exact version and moves it up deliberately. Each core
     change the shell needs is a Swiit release first.
   - Keep the release cadence cheap: a tag and its CI, no more.

Stages 1–2 are the bulk of the work. Stage 3 overlaps with retiring the hand
parser, and 4–6 are short.
