# Self-Hosted Elm Compiler — Design

**Date:** 2026-07-04
**Status:** Draft for review

## Summary

Rewrite the Elm compiler in Elm, as a pure Elm project bootstrapped by this
Haskell fork. One pure compiler core serves three shells: a Node CLI (the
`elm make` replacement), a browser build (client-side compilation for
playgrounds/LiaScript), and — once the core can compile its own source —
self-hosting. The parser is built on `andre-dietrich/parser-combinators`,
evolved into a compiler-grade library as part of this project. Package
management moves to GitHub release tags as the source of truth, with the
official version-range semantics kept.

## Decisions (from brainstorming, 2026-07-04)

| Question | Decision |
|---|---|
| Goal | All three: browser compiler, CLI replacement, true self-hosting |
| Language surface | Full Elm 0.19.2 **plus** this fork's `<-` / `.{}` record syntax |
| Error messages | Match official quality (wording, hints, layout) |
| Parser | Evolve `parser-combinators` compiler-grade (contexts, committed choice, indentation) |
| Packages | GitHub tags as versions, official range semantics, no central registry |
| Kernel code | **Not** opened up. Official rule stands (`elm/`, `elm-explorations/` only). No `elm/fs`; all IO lives in shells via ports |
| Strategy | Faithful port, phase by phase in pipeline order, differential-tested against the Haskell fork |

## Non-Goals

- No new kernel-code capability for third-party packages. The compiler core is
  pure; the purity guarantee of the ecosystem is preserved.
- No replacement of the Haskell fork in the near term — it stays the bootstrap
  compiler and the differential-test oracle.
- No new language dialect beyond what the fork already accepts.
- Source maps, reactor, repl: out of scope for this spec (later projects).

## Architecture

### Pure core + thin shells

The core is ordinary pure Elm: no ports, no Cmd/Sub, fully unit-testable.

```
Compiler.compileModule :
    Interfaces -> SourceText
    -> Result Error (Interface, LocalGraph)
```

mirroring `compiler/src/Compile.hs`. Multi-module orchestration (the analog of
`builder/src/Build.hs` + `Generate.hs`) is also pure, written as an
**effects-as-data state machine** so the same builder logic drives every shell:

```
Builder.init  : Flags -> ( State, List Request )
Builder.step  : Response -> State -> Step

type Request  = ReadFile Path | ListDir Path | GetTags PackageName
              | GetZipball PackageName Version | ReadCache Key | WriteCache Key Bytes | ...
type Response = FileRead Path (Result IoError String) | Tags PackageName (List Version) | ...
type Step     = Running ( State, List Request ) | Done (Result Errors Output)
```

Shells fulfill `Request`s and feed `Response`s back until `Done`:

- **CLI shell** (`cli/`): an Elm `Platform.worker` under Node, IO via ports; a
  small JS driver (~200 lines) maps requests to `fs`, `https`, a cache dir
  (`~/.elm-self/`), and ANSI stdout. Error rendering to ANSI happens in the
  core; the shell only prints.
- **Browser shell** (`web/`): virtual file system (`Dict Path String`),
  packages fetched over HTTP (see Packages), errors rendered to HTML.
- **Self-host**: gen-1 (this compiler compiled by the Haskell fork) compiles
  its own source under the CLI shell.

### Repository layout

A new top-level directory in this repo (monorepo keeps the differential-test
oracle — the Haskell binary — and the corpus in one place; extract to its own
repo once self-hosting works):

```
selfhost/
  elm.json              -- application; source-directories include vendor/
  src/
    Compiler/           -- the pure core
      Parse/  AST/  Canonicalize/  Type/  Nitpick/  Optimize/  Generate/
      Reporting/        -- error types + doc rendering (ANSI + HTML renderers)
    Builder/            -- effects-as-data crawl/plan/build state machine
  vendor/
    parser-combinators/ -- git subtree / copy of andre-dietrich/parser-combinators
  cli/                  -- Node driver + ports Main
  web/                  -- browser demo shell
  tests/                -- elm-test unit tests
  corpus/               -- differential-test harness (Node) + pinned test packages
```

Vendoring via `source-directories` avoids needing GitHub-package support in the
*bootstrap* compiler; published packages (`elm/core`, `elm/json`,
`elm-explorations/test`, a pretty-printer) install normally.

### Module-by-module porting map

Each core module ports its Haskell counterpart; names stay parallel so the two
codebases can be read side by side.

1. **Parse** — built on parser-combinators, evolved with:
   - byte/char offset + row/col position tracking,
   - a **context stack** (`inContext`-style: "while parsing this record…"),
   - **expected-token sets** accumulated on failure,
   - **committed choice** (after a keyword/token commits, alternatives stop
     backtracking — errors point at the real problem, matching official
     behavior),
   - **indentation state** (current indent column; `checkIndent`-style
     combinators) for Elm's layout rules.
   These land in the vendored library (it becomes v-next of
   `andre-dietrich/parser-combinators`). Grammar modules mirror
   `Parse.Expression/Pattern/Type/Declaration/Module`, including the fork's
   `<-` and `.{}` record-update syntax.
2. **AST** — `Source`, `Canonical`, `Optimized` as Elm custom types, direct
   transcriptions. No binary caching format initially (recompile from source;
   an interface cache is a later optimization).
3. **Canonicalize** — import/name resolution, fixity resolution, sugar
   lowering (including the fork's record syntax, same as it lowers here).
4. **Type** — constraint generation ported from `Type.Constrain.*`; solving
   ported from `Type.Solve`/`Type.Unify`. The Haskell union-find is
   IORef-mutable; the Elm port uses a **persistent union-find**: variables are
   `Int` ids into a `Dict Int PointInfo` threaded through the solver state,
   with union-by-rank and path compression on lookup (compression writes back
   into the threaded state). Benchmark at milestone M4 against real packages;
   this is the number-one performance risk.
5. **Nitpick** — exhaustiveness checking (`Nitpick.PatternMatches`).
6. **Optimize** — decision trees, tail-call detection, dead-code graph.
7. **Generate.JS** — Dev mode first (the debugger/`Debug.toString` contract),
   then Prod mode. The fork's own optimizations (field shortnames, arity
   tables, unwrapped HOFs, shape padding, TRMC) are ported **after**
   self-hosting works — they then directly speed up the self-hosted compiler
   itself.
8. **Reporting** — ported per phase alongside that phase, not as a big bang:
   each milestone includes its error types (`Reporting.Error.Syntax` with M2,
   `…Canonicalize` with M3, `…Type` with M4). Rendering ports
   `Reporting.Doc`/`Render.Code` (code snippets with carets, suggestions) on a
   Wadler-Leijen pretty-printer (`the-sett/elm-pretty-printer` if adequate,
   else a small port). Two renderers: ANSI (CLI) and HTML (browser). Total
   Haskell source here is ~12k lines — it is a first-class workstream, and
   "match official quality" is verified by golden tests, not vibes.

### Packages from GitHub

Implemented in `Builder` (the new compiler only; no backport to the Haskell
fork).

- `elm.json` stays format-compatible; the package identifier `author/project`
  now literally means `github.com/author/project`.
- **Versions = release tags** (`MAJOR.MINOR.PATCH`, same as today — the
  official registry already requires git tags; this just drops the central
  index).
- **Resolution**: port the official backtracking solver (`Deps.Solver`);
  version listings come from `GetTags`, package contents from `GetZipball`.
  The shell decides transport:
  - CLI: GitHub API for tags (unauthenticated is rate-limited to 60/h —
    mitigate with an aggressive local cache and optional `GITHUB_TOKEN`),
    `codeload.github.com` for zipballs.
  - Browser: **jsDelivr** (`data.jsdelivr.com` for tag lists,
    `cdn.jsdelivr.net/gh/author/project@tag/…` for files) — CORS-enabled and
    cached, so playgrounds work without a proxy or token.
- **Kernel rule unchanged**: packages containing `src/Elm/Kernel/*.js` are
  rejected unless author is `elm` or `elm-explorations` (whose repos are on
  GitHub anyway, so core installs need nothing special).
- Lost vs. the registry and accepted: enforced semver-vs-API validation,
  central docs hosting, download counts.

## Testing strategy

1. **Unit tests** (`elm-test`): per-combinator, per-grammar-rule, per-phase.
   The pure core makes every phase directly testable.
2. **Differential corpus** (the main safety net): a Node harness compiles each
   corpus project with (a) the Haskell fork binary and (b) the new compiler,
   then asserts **behavioral equivalence** — the generated JS is executed
   under Node and outputs compared (textual JS diff is a non-goal; Dev-mode
   output is compared more strictly than Prod). Corpus: `elm/core`,
   `elm/json`, `elm/html`, `elm/parser`, `andre-dietrich/parser-combinators`,
   selected community packages, and — always — the new compiler's own source.
3. **Error goldens**: a curated suite of broken programs; the rendered error
   text is snapshot-tested. "Match official quality" = goldens are seeded from
   the official compiler's output and diverge only deliberately.
4. **Self-host fixpoint** (final gate): gen-1 (built by Haskell) compiles the
   compiler → gen-2 JS; gen-2 compiles the same source → gen-3 JS;
   `gen-2 === gen-3` byte-for-byte.

## Milestones

Pipeline order; every milestone leaves a runnable harness. Exit criteria are
checkable, not aspirational.

- **M0 — Scaffold.** `selfhost/` builds via the Docker recipe; corpus harness
  runs the Haskell oracle; CI-able one-command test script.
- **M1 — parser-combinators, compiler-grade.** Positions, context stack,
  expected sets, committed choice, indentation state. Exit: unit suite green;
  library API documented.
- **M2 — Parser.** Full grammar incl. fork syntax → `AST.Source`. Exit:
  parses the whole corpus without error; syntax-error goldens match official.
- **M3 — Canonicalize.** Exit: corpus canonicalizes; naming/fixity error
  goldens pass.
- **M4 — Type check.** Exit: corpus type-checks; type-error goldens pass;
  concrete performance bar: type-checking the full corpus under Node
  completes in under 60 s total (revisit the number after first measurement,
  but a number is the exit criterion — see Risks).
- **M5 — Nitpick.** Exhaustiveness. Exit: goldens for missing-pattern errors.
- **M6 — Optimize + Dev codegen.** Exit: corpus apps behave identically under
  Node vs. oracle output.
- **M7 — Builder + CLI shell.** `node elm-self.js make src/Main.elm` on a real
  project with vendored deps. Exit: compiles corpus projects end-to-end from
  disk.
- **M8 — GitHub packages.** Tag solver + zipball download + cache. Exit: fresh
  checkout with only `elm.json` builds, including a GitHub-only package
  (`andre-dietrich/parser-combinators`).
- **M9 — Browser shell.** Playground page: type Elm, get running output,
  packages via jsDelivr. Exit: demo compiles an `elm/html` app fully
  client-side.
- **M10 — Self-host.** Fixpoint test passes. Then: port the fork's Prod-mode
  optimizations and measure the compiler speeding itself up.

## Risks and mitigations

- **Typechecker performance** (pure union-find vs. IORefs): benchmark at M4,
  not at the end. Mitigations in order: rank+compression tuning, solving in
  dependency-group batches (already how it works), and — since the compiler
  compiles itself — the fork's codegen optimizations. Accept 5–20× slower than
  Haskell initially; a browser compiler and a dev-loop CLI have different
  bars, and both are far below "instant" Haskell today anyway.
- **Reporting scope creep** (~12k lines): bounded by porting per-phase with
  goldens seeded from official output; no open-ended "make errors nice" work.
- **elm-in-elm trap** (parser never finishes): countered by making M2's exit
  criterion "parses the full corpus", measured continuously, before any later
  phase starts.
- **GitHub rate limits / availability**: aggressive immutable cache (a
  tag's zipball never changes), optional token, jsDelivr as browser transport.
- **Docker-only dev loop**: all harness scripts must run inside the existing
  `haskell:9.8.4` + Node containers with named volumes; no local toolchain
  assumptions.

## Open points (defaulted, changeable)

- Project/binary name: working name `elm-self`; directory `selfhost/`.
- Pretty-printer: try `the-sett/elm-pretty-printer` first, port if it can't
  express `Render.Code`'s layouts.
- Interface caching (`.elmi`-equivalents) deliberately deferred until after
  M10.
