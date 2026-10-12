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
  `SwiitKit` and ships `SwiitStandardLibrary`, and lends hosts a
  `HostContext`.

Moving now would freeze all three in their current shape. Moving after
settling them costs little more than moving now, and the history comes along
either way.

## The plan

Each stage is useful on its own, inside this repository; the move is the
last stage, and mechanical by then.

1. **Count the SPI and stop it growing.** A test like the boundary ledger
   lists the `@_spi(Shell)` declarations the shell uses
   (`spi-surface.txt`); a new one fails the test until it's added on purpose.
   The list only shrinks from then on. *Done:* `theCoresSPIOnlyShrinks`
   checks Packages/Swiit/Tests/SwiitTests/spi-surface.txt against every
   `@_spi(Shell) public` declaration in Sources/Swiit. Before it was written,
   the 188 members nothing outside the module named became internal: 878
   declarations went to 690. Of those, by the names other code uses
   (approximate): 566 the shell's, 83 only the core's own other modules'
   (the SwiftSyntax front end, the bridge generator), 11 only tests', and 30
   that name nothing outside (types public signatures need, and protocol
   requirements' defaults). Then the 40 members only the core's own other
   modules use moved to `@_spi(Swiit)`, which the shell doesn't import, so
   `@_spi(Shell)` is what the shell uses (650 declarations, types included,
   since one can be used without its name) and the ledger says which is which.
   (Stage 2 then split `@_spi(Shell)` by purpose.)
2. **Design the host API.** What the shell uses, sorted into what any host
   needs (made `public` and documented in embedding.md: tasks and the lock,
   `SwiitHost`, `statementFinished`, `inputTurn`, `owner`, registering object
   members, installing libraries) and what's the shell's habit (moved into
   the shell, or behind a narrower call). An `@_spi(Swiit)` stays only for
   things the core's own modules (`SwiitSwiftSyntax`, the bridge generator)
   share. Done when the shell imports Swiit without `@_spi`.
   *Started:* the shell's SPI is sorted into groups by purpose, and each file
   imports only the groups it uses, so where the shell reaches in shows in its
   imports:
   - `Host` (304 declarations): what any host needs, the candidates for public
     API. Sources/Swiit/Host; the interpreter's own type, its lock, tasks and
     errors; defining and calling functions (`Function`, `FunctionBody`,
     `OverloadSet`, `invoke`, `call`, overload resolution); streams
     (`ValueStream`); globals (`Scope`, `Binding`, `lookup`); inspecting values
     and declared types (`typeName`, `conform`, `member`, `StructType`,
     reflection for help); running code (`run`, `runBlock`, `runDeferred`,
     `checkInterrupt`); and the bridge's tables and glue, which a host's
     generated library calls.
   - `Layer` (323): what a syntax layer builds on, the tree, the parser and the
     checker (Language/Syntax, Language/Checking). Stage 3 narrowed it, to 221.
   - `Swiit` (40): only the core's own other modules.

   The evaluator's insides are in none of them: they're internal. There was
   an `Internals` group, 211 declarations the shell reached into by file, and
   it's empty now. The command-line argument (`CommandArgument`), which only
   the shell used, moved to the shell; a piped value's method is read as a
   member, bound to it (`member(_:of:)`), instead of from its struct's method
   table; what any host needs, by the list above, moved to `Host`; and the
   rest, the evaluator's own (`apply`, `compare`, `construct`, the bridge's
   generated tables), became internal.

   Of the shell's 44 files that import the core, 32 use `Host`, 27 `Layer`,
   and 8 none.

   *Done:* `Host` is public, documented by area in embedding.md ("The public
   API, and what stays SPI"), and the core's embedding tests import `Swiit`
   without `@_spi`. Making it public drew the line between a host and a
   syntax layer: what needs the tree to say is a layer's, so `parse`, `run`
   of a parsed program, `runBlock`, `runDeferred`, `statementFinished` and its
   observers, `syntax`, `frontEnd`, `globalNames`, the scope stack, and the
   checker's tables (`sequenceMethods`, `staticTypes`) went to `Layer`.
   `Program` is public but opaque, so a function's body can be. Of the tree's
   types, the ones a function's signature needs are public: `TypeAnnotation`
   (with `Effect`), `Parameter`, `Documentation`. What nothing outside used
   became internal (`Binding`'s special kinds, a scope's weak fallbacks, the
   evaluator's control flow), and the test of how closures capture scopes
   moved to the core, where it can look at them. The SPI is now 376
   declarations: 336 `Layer`, 40 `Swiit`. The shell still imports `Layer` in
   most files that touch the core; stage 3 is where that narrows.
   *Narrowed* (2026-10-12): the compiler decided. Every `Layer` declaration
   was made internal and the shell was built; what it named came back, and
   the rest stayed internal, 100 of the 321. The shell's tests see the tree
   through `@testable import Swiit`, so they no longer hold it open. What
   remains is the tree (its nodes, with the initializers a layer builds
   them by), `SourceCursor` and `SyntaxPlugin`'s needs, the checker's
   hooks for a layer's pipelines, and the front end's own entry points.
3. **A syntax-plugin contract without the parser's internals.** *Done*
   (2026-10-11), and more: the hand parser is retired (frontend.md, "Retired").
   The plug-in reads with a `SourceCursor`, which scans and records, and asks
   for Swift's grammar in five places. What is still `Layer` is the tree, the
   checker's hooks and the cursor, not a parser's internals. Original plan: Either the
   hand parser retires and the plugin works on SwiftSyntax tokens (frontend.md's
   end state), or `SyntaxPlugin` gets a small public cursor (peek, take, spans,
   recover) that the hand parser and the lowering both implement. The second
   is cheaper and doesn't wait on retiring the parser, so it comes first.
4. **Names.**
   - Error reports take their prefix from the host (`SwiitHost.name`, `swish`
     in the shell, `swiit` by default).
   - `SwiitStandardLibrary` becomes `SwiitStandardLibrary`.
   - `HostContext` becomes `HostContext`.
   - SwiitKit: the value model and the plugin ABI are the interpreter's, so
     it moves with Swiit as `SwiitKit`. A plugin compiled against it works in
     any host. The shell keeps a `SwiitKit` re-export, or plugins move over
     with a deprecation period.
   - Check that "Swiit" is free as a GitHub organization or repository name
     and on the Swift Package Index before anything is published.
   *Done* (2026-10-11), with these decisions:
   - The standard library split by owner: what the interpreter bridges or uses
     is `SwiitStandardLibrary` (`Flow`, the `Date`, `FilePath` and `Sequence`
     extensions, `TextStyle`); `DisplayFormatter` and `PrettyPrinter`, the
     terminal's layout of values, moved to the shell's `SwishShellLibrary`.
   - `SwiitKit` is the kit's package, module, macros (`@SwiitExport`,
     `@SwiitObject`) and types (`SwiitObject`, `SwiitError`,
     `SwiitConvertible`, `SwiitDisplayed`, `SwiitEnum`, `SwiitValue`;
     `HostContext`). It keeps the old type and macro names, deprecated, and
     `Packages/SwishKit` is a package of the old name that re-exports it, so a
     plugin written against SwishKit builds unchanged, manifest included (the
     example plugin does, and a test keeps it so). A protocol requirement
     implemented by hand is the one thing that must be renamed.
   - The core's own: `SwiitHost`, which names the program errors are reported
     under (`swiit:` by default, `swish:` in the shell); `FunctionBody.swiit`;
     the comments and messages that mean the language say Swiit.
   - The name: the GitHub account `swiit` is taken (a user since 2013, with no
     public repositories), so the repository needs another owner, the
     author's own or an organization of another name; a few unrelated small
     repositories are called Swiit. The Swift Package Index has no package of
     the name.
5. **Stand-alone build and CI, still in this repository.**
   - `swift test --package-path Packages/Swiit` already runs alone.
   - Its CI job also builds and tests with no path outside `Packages/` (no
     `../SwiitKit` once SwiitKit lives inside it). It runs the bridge
     generator check against `Packages/Swiit/Bridges` only.
   - The shell's bridges and manifests stay with the shell.
   - *Started* (2026-10-12): `Swiit alone` jobs (macOS, Linux) check out only
     `Packages/Swiit` and `Packages/SwiitKit`, then build and test both. Still
     to do: the bridge-currency check, which runs from the shell's
     `run bridge`, and so needs the generator to be runnable by itself.
6. **Docs split.**
   - These go with Swiit: embedding.md, frontend.md, types.md, callables.md,
     swift-interop.md, foundations.md, the core parts of async.md and
     boundaries.md, and the interpreter half of vision.typ.
   - These stay: desugaring.md, pipeline.md, plugins.md (pointing at Swiit's
     plugin ABI) and syntax.md.
7. **The move.**
   - Copy the history out with
     `git filter-repo --subdirectory-filter Packages/Swiit` (plus the moved
     SwiitKit and docs paths, with `--path` and `--path-rename`) into the new
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
