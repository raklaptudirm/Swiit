# The front end

The front end turns text into the core's syntax tree. Today it is a
hand-written parser. The intention is to replace it with SwiftSyntax, so that
Swish accepts Swift's syntax by construction and follows the language as it
grows. This note fixes what stays the same across that swap (the contract, and
how the shell plugs in), records what was learned about SwiftSyntax, and gives
the steps. It builds on [embedding.md](embedding.md) and
[boundaries.md](boundaries.md): the core is Swift only, and the shell's grammar
is a layer over it.

## The contract

A front end takes source text and the names already in scope, and gives back one
of three things: a program in the core's tree; syntax errors, each with a range;
or "incomplete", so a prompt can ask for another line. It also gives highlight
spans for the line editor. Provisionally:

```swift
protocol SyntaxFrontEnd {
    func parse(_ source: String, names: [String: NameKind], shell: ShellSyntax?) -> ParseResult
    func highlight(_ source: String, names: [String: NameKind]) -> [Span]
}
```

The hand parser is the only implementation today. Its `Parser.Dialect` (step 3)
becomes "is a `ShellSyntax` plugged in?": no plug-in is the Swift dialect.

## The shell's plug-in

The shell's grammar nests inside Swift's and Swift's inside it: closure words
(`where { $0.size > 1.mb }`), `\(expr)` in words, `$(…)` holding a whole
program; and commands as statements in function bodies, as conditions
(`if make { … }`), and in `for x in $(cmd)`. So the shell can't be a separate
parser; it has to plug into the front end, and call back for the Swift inside
it.

The plug-in works on **statements and spans of text**, not on tokens:

- Given the text ahead, the names in scope and the context (in a condition, in a
  guard, under `try`): is it a command, and where does it end?
- Given a command's span: parse it into a shell node, calling back to the front
  end for any embedded Swift span.
- The expression-level forms: `$(…)`, `$NAME`, `async …`, and `import … from path`.

The core's tree gets **one opaque extension node** (for expressions and for
units), replacing `PipelineNode`, `CommandNode`, redirects and the rest in its
`switch`es. The checker gets a hook to visit the Swift nested in such a node.
The desugaring ([desugaring.md](desugaring.md)) rewrites the nodes into Swift
calls after checking, as planned.

Token-level hooks in the hand parser would have been simpler to write and would
be thrown away: SwiftParser has no such hooks (below), so the interface is
shaped for what survives the swap.

### The grammar's hooks, named

Racket names the edges of its grammar (`#%app`, `#%datum`, `#%top`,
`#%module-begin`) so a language can replace them. The shell's plug-in does
the same, though today as structural tests in `ShellSyntax`: an unbound name
at the head of a line is `#%top` (command lookup), words after it are
`#%app`'s arguments, and `$name` and `$(…)` are its own forms. The plug-in's
contract should name these and take them as hooks, so a second front end
implements the same list. The plug-in is chosen when the interpreter is made,
like `#lang`, and nothing changes the grammar mid-session.

## SwiftSyntax as the front end

### What the documentation and source say

- **No grammar extension point.** SwiftParser's public API is `Parser`, `Lexer`,
  `SyntaxParseable`, `IncrementalParseTransition` and `ExperimentalFeatures`; no
  delegate, hook or rule type. No forum thread asks for one.
- **Structure, not messages, is the supported surface for non-Swift text.** The
  parser "produces no errors regardless of how ill-formed the input source text
  is". Syntax it can't place becomes `unexpected` nodes and absent syntax
  becomes `missing` tokens; diagnostics are a separate pass over the tree. It can
  start at any production (a file, a type, a single expression).
- **Macros are not a grammar mechanism.** They expand `#name(…)` and `@name`
  annotations that are already valid Swift. There is an in-process expansion API
  (`expandFreestandingMacro`, `BasicMacroExpansionContext`), so macros could
  carry the desugaring, but not the recognition.
- **`SwiftLexicalLookup`** (new in 602, the version already pinned for the
  macros) answers "what does this name refer to here" with Swift's scoping.
  **`SwiftOperators`** folds operator sequences by a configurable table.

### What was tried

A scratch spike against swift-syntax 602, not in the repository.

| Input | SwiftParser's tree |
|---|---|
| `ls -la`, `git status`, `echo $HOME`, `ls ~/bin` | Consecutive expression statements on one line; the first item's `;` is a **missing token** (public `presence == .missing`), unlike a real `;` or a newline |
| `ls --all \| where { … }`, `cat *.swift \| wc -l`, `make && echo ok \|\| …`, `echo hi > out.txt` | Operators parse as Swift operators; the words are cut into odd fragments (`-l` ends up separate) |
| `echo don't stop`, then two Swift lines | Damage stays on that line; the next lines parse normally |
| `grep /foo/ file.txt` | `/foo/` is lexed as a regex literal |
| `let x = $(date)`, `try make` | Parse cleanly (`$` is an identifier; `try` of a reference) |
| `if grep -q x f { echo yes }` | One `if`; `-q x f` is a single `unexpectedNodes` node whose parent is the body block |
| `FOO=bar make`, `async sleep 1` | Split into pieces |
| `_ = 1 + 2`, protocols, generics, actors | Parse cleanly |
| `let xs = [1, 2,` | A tree, with "expected ']' to end array" |

- **Lexical lookup** follows Swift's sequential rules inside blocks (`local` is
  unknown before its `let`, declared after). **Top-level names come back empty**;
  wrapping the program in a code block fixes it.
- **`SwiftOperators`** folded a pipeline with the stock `|`. A custom pipe
  precedence reported the groups "incomparable" in three attempts, so don't rely
  on it; the left operand of a command pipeline isn't a valid expression anyway.
- **Speed:** 3.65 ms for 1,000 lines, 3 µs for a short line.
- **Size:** the spike's release binary is 17.8 MB, of which 12.8 MB is symbol
  tables; **fully stripped it is 6.2 MB**, against 3.45 MB for `swish`
  (`strip -x`: 9.2 MB against 3.45). The code is 3.8 MB: SwiftSyntax 2.63 MB
  (69%, its generated node types: 48,331 functions), SwiftParser 0.75 MB (20%),
  SwiftParserDiagnostics 0.20 MB. A clean release build of the stack took
  2 min 26 s here (debug: about 36 s).

### How the front end would work

1. SwiftParser parses the source.
2. **Recognition** is by structure and scope. A statement whose items are
   separated by a missing `;` is a command line, and so is a bare reference to a
   name that isn't in scope there (lexical lookup, with the program wrapped in a
   code block; names from outside the tree, like builtins and earlier prompt
   entries, come from Swish's own tables). The shell takes the command's **text by
   range** from the original source, never from tokens, and parses it itself.
3. **Islands** the parser doesn't carve (a command in a condition, `$(…)` with
   non-Swift contents, `FOO=bar cmd`, `async cmd`) are rewritten by a small
   pre-pass into valid Swift placeholders, with a source map for positions. For
   an `if` the unexpected node already gives the rest of the command by range.
4. **Lowering** turns the Swift tree into the core's tree. A construct it doesn't
   lower is an explicit "not supported yet: protocol declarations", so the
   supported subset is the set of lowered node kinds, documented and tested. The
   checker and the interpreter don't change.
5. **The editor** gets highlight spans from the tree, incomplete input from
   missing tokens at the end of the source, and re-parsing from
   `IncrementalParseTransition`. (None of these is built or tried.)

### Costs and risks

- **Size and build time** are real for an embeddable language. Because the front
  end is behind the contract, SwiftSyntax can be an optional module and the hand
  parser stay as the light option.
- **Recovery is best-effort, not a contract.** It could change between
  swift-syntax releases. A **conformance corpus** of shell lines (the spike's
  samples to begin with), run through the front end and pinned to the version,
  catches drift; upgrades are deliberate.
- **Version coupling:** swift-syntax tracks compiler releases and its node API
  changes between majors, so the lowering needs maintenance.
- **Lexical lookup** is young: top-level names need the wrapper, parts are
  `@_spi(Experimental)`, and qualified lookup is still being built.
- **Semantics don't move.** SwiftSyntax settles syntax; what counts as supported
  is still the checker's and the interpreter's.

### Retiring the hand parser

Keep it as the oracle. Run both front ends over the Swift-only subset of every
test program and compare the trees; the hand parser goes once the lowering
matches it on that corpus. The same corpus, run through `swiftc`, is the
differential test against real Swift ([direction.md](direction.md)); it already
has one catch, `_ = expr`, which Swish reads as a command named `_`.

## Plan

Steps 3b and 3c of [the embedding plan](embedding.md), each its own change.

**3b. The contract and the plug-in, on the hand parser.**
*(Status: the plug-in and the opaque nodes are built; the `SyntaxFrontEnd` protocol and `package` access are deferred to 3c and step 4. The plug-in takes the parser itself, not a text cursor.)*
- Define `SyntaxFrontEnd` and `ShellSyntax` (span-level, with callbacks for
  embedded Swift) and make the hand parser the first implementation; `Parser`'s
  internals become `package` so the shell target can extend them.
- Replace `PipelineNode`, `CommandNode`, redirects and stage resolution in the
  core's tree with the opaque extension node; add the checker's visit hook.
- Move the shell's grammar behind the plug-in in place (`Parser+Commands`,
  `CommandNodes`, and the shell branches that step 3 gated), so that step 4 can
  move the files into `SwishShell`.
- Tests: every existing parser test passes unchanged; the Swift dialect is "no
  plug-in".

**3c. A SwiftSyntax front end.**
- A second implementation of the contract: parse, recognise, lower, with the
  island pre-pass and source map; an optional module.
- Tests: the oracle comparison against the hand parser; the conformance corpus;
  `swiftc` differential tests of the Swift-only subset.
- First prove the untested pieces (below).

## Tried for 3c

A second scratch spike (swift-syntax 602, not in the repository).

- **`$(…)`.** With Swift inside (`$(date)`, `$(ls).count`) it parses as a call
  to a function named `$`, with no diagnostics. With shell inside
  (`$(date +%s)`, `$(ls | wc -l)`) it is the same call with the unparsable
  tail in an `unexpectedNodes` child. So the front end finds the `$` call and
  takes the text between its parentheses **by range**, as planned. `echo $HOME`
  and `echo "a \($(date)) b"` split like any other command line: a missing `;`
  after `echo`.
- **A single expression** (`ExprSyntax.parse(from:)`) always consumes the whole
  input: trailing text becomes `unexpectedNodes` and diagnostics, and
  `Parser.currentToken` is internal, so there is no way to ask where it
  stopped. Embedded Swift in command words (`\(expr)`, closure words) must
  therefore be **cut out by the shell first** (balanced delimiters, string
  aware) and the span handed over; the parser can't find the end of an
  expression inside a word.
- **Incomplete input** shows up as a diagnostic "expected X to end ..." (array,
  function, `if`, string literal) on a missing token at the end of the source,
  so the prompt's "ask for another line" is: any missing token whose position
  is the end of the source.
- **Lowering target.** The core's tree (`Expr`, `Statement`, `Unit` and the
  rest) is `internal` to Swiit, so a separate front-end module can't build
  it until step 4 makes it `package`. Step 4a has: the tree is `package` in
  `Swiit`, so the lowering can live in its own module. It is not started.

## Built

Slices 1 to 3 of 3c (the `SwiitSwiftSyntax` module in `Packages/Swiit`):

- **The contract:** `SyntaxFrontEnd` (`parse(source, bound, plugin)`), with the
  hand-written parser as `HandWrittenFrontEnd`; `Interpreter.frontEnd` picks
  one. The module is an optional product, since swift-syntax adds size.
- **Lowering Swift:** `SwiftSyntaxFrontEnd` lowers SwiftParser's tree to the
  core's: expressions (literals, strings with interpolation, file sizes like
  `2.mb`, operators folded by `SwiftOperators`, closures, key paths, casts,
  `try`/`await`, optionals), statements (`if`/`guard`/`while`/`for`/`switch`/
  `do`/`catch`/`defer`), functions (parameters, `@flag`, `@input`, `///`
  documentation, `throws`), structs (stored and computed properties, methods,
  initializers, statics read through the type's name in static members) and
  enums. A construct it doesn't lower is an error naming it.
- **The oracle:** the hand parser's tree for the same source. 32 programs
  covering each construct, and the 226 Swift-only programs harvested from the
  suites' 739 distinct sources, read as the same tree: 223 agree, none differ, and
  three are not lowered (a type, a placeholder, and `f -5 -3`, which is
  arithmetic to the hand parser and, as in Swift, two statements to SwiftParser).
  The count of those only goes down.
- **Problems:** input cut short is `incomplete` (a missing token at the end of
  the source), as the prompt asks for another line; other problems are errors
  with a line. Both front ends agree on which is which for 22 inputs.
- **Found by the oracle:** the hand parser grouped `a ?? b ?? c` to the left;
  Swift groups it to the right. It is fixed.

- **Shell lines (slice 4):** the shell's plug-in runs unchanged, through a hand
  `Parser` positioned at a byte offset in the source, with the names the
  lowering knows (locals, members, statics, functions, `self`, `try` depth).
  It reads statements that start with a command, `import`, a chain with a
  command after `&&`/`||`, conditions that are commands, `$(…)`, `$name`,
  `async`, and `xs | sorted`. The spans it read are recorded, and SwiftParser's
  problems inside them are ignored, as its tree there is a guess at text that
  isn't Swift. When SwiftParser reads one item over several statements
  (`ls > out; head out`, taken for a regular expression), the rest are read
  from where the plug-in stopped. Assignments, `$0` and keyword statements stay
  Swift's, as in the hand parser's dispatch.
- **The shell-side oracle:** of the 709 harvested programs the hand parser
  reads with the shell's syntax, 663 give the same tree, none differ, and 46 are
  not read yet (mostly a command word SwiftParser stops at, such as an
  unmatched quote). A ratchet holds that count.

Not built: highlighting from the tree and wiring the front end into the shell.

## Not tried yet

- Highlighting with `SwiftIDEUtils` and incremental re-parsing.
- Whether names declared in earlier prompt entries can be fed to lexical lookup
  other than by Swish's own tables.
- How large the lowering is; I expect it to be smaller than the 3,400 lines of
  hand-written parser it would replace, but I haven't written one.
