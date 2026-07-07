# Cyclic Modules — Plan 1: Cross-Module Cycle Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify, in isolation from `Build.hs`'s live scheduler, the three pieces a restricted cross-module cycle needs: a reusable direct-dependency (CAF) cycle detector, a stub-`Interface` constructor, and a harvest pass that resolves a cyclic SCC's types and explicitly-annotated exposed signatures without needing any member's full compile to finish first.

**Architecture:** A new `Canonicalize.Harvest` module treats a cyclic SCC of `Src.Module`s the same way `Canonicalize.Environment.Local` already treats one module's own declarations — register every union/alias name+arity across the whole SCC first, then resolve bodies using an env that can see the whole SCC — except generalized across module boundaries (each declaration keeps its own `home`, unlike today's single-`home` `Local.add`). It reuses `Canonicalize.Environment.Foreign.createInitialEnv` unchanged for each member's imports that fall *outside* the SCC, and reuses `Canonicalize.Module.canonicalizeExports` unchanged for export resolution (both take exactly the shapes this pass already produces). Verification in this plan runs each new function directly against hand-written `Src.Module` values (parsed via `Parse.fromByteString`), independent of `elm make` / `Build.hs` — that wiring is Plan 2's job.

**Tech Stack:** Haskell (GHC 9.8.4, `cabal`), compiled inside the `haskell:9.8.4` Docker image per this repo's build recipe. No automated test suite exists in this repo; verification here uses a throwaway `cabal repl` session driving the new functions directly against literal source strings (there is no `Build.hs` entry point to exercise yet — that's Plan 2).

## Global Constraints

- `-Wall -Werror` is baked into `elm.cabal`'s `ghc-options` — any GHC warning fails the build, including unused binds/imports and incomplete patterns.
- Build via Docker (`haskell:9.8.4`) with named volumes (`elm-cabal-home`, `elm-dist`); use `--ghc-options=-O0` for the iteration loop.
- **v1 restrictions baked into this plan** (see `docs/superpowers/specs/2026-07-07-cyclic-modules-design.md` and its corrections):
  - Only `type` (union) declarations may be mutually recursive across a cyclic SCC's modules. `type alias` cycles across the SCC boundary are rejected exactly like today's intra-module `RecursiveAlias`.
  - Every value *exposed* by a module that participates in a cyclic SCC must carry an explicit top-level type annotation — not just the ones actually referenced cross-module. (Deliberate v1 simplification: precise "only the ones actually used cross-module" usage analysis is deferred; requiring it for every exposed name is simpler to implement/explain and a reasonable ask of an exposed API surface.)
  - No ports, effect managers (`Src.Manager`), or custom infix operators (`binops`) in any module that's part of a cyclic SCC. Checked explicitly and rejected with a clear error — not silently mishandled.
  - This plan does **not** touch `Build.hs`, does **not** allow `elm make` to actually compile a cyclic project yet, and does **not** implement the cross-module CAF/value-cycle *rejection* end-to-end (Task 2 builds the detector as a reusable, tested function; Plan 2 is what calls it after a real Pass-B compile and turns a positive result into a build failure).
- This is genuinely novel code with no existing pattern to copy verbatim (unlike most prior perf-focused plans in this repo). Task 4 in particular should be expected to need iteration against real GHC type errors beyond what's shown here — each step's "build to confirm" is not a formality.

---

### Task 1: New `BuildProjectProblem` error cases

**Files:**
- Modify: `builder/src/Reporting/Exit.hs`

**Interfaces:**
- Produces:
  - `Exit.BP_CycleValue :: NE.List (ModuleName.Raw, Name.Name) -> Exit.BuildProjectProblem`
  - `Exit.BP_CycleMissingAnnotation :: ModuleName.Raw -> Name.Name -> Exit.BuildProjectProblem`

These aren't called from anywhere yet (nothing in the live compiler can produce a cyclic SCC that reaches this point until Plan 2) — this task only adds the constructors and rendering, verified by rendering hand-built values in `cabal repl`.

- [ ] **Step 1: Add the two constructors**

In `builder/src/Reporting/Exit.hs`, find:

```haskell
  | BP_Cycle ModuleName.Raw [ModuleName.Raw]
  | BP_MissingExposed (NE.List (ModuleName.Raw, Import.Problem))
```

Replace with:

```haskell
  | BP_Cycle ModuleName.Raw [ModuleName.Raw]
  | BP_MissingExposed (NE.List (ModuleName.Raw, Import.Problem))
  | BP_CycleValue (NE.List (ModuleName.Raw, Name.Name))
  | BP_CycleMissingAnnotation ModuleName.Raw Name.Name
```

(`Name.Name` is already imported in this file via `Elm.ModuleName`'s re-export path used elsewhere in `Exit.hs` — check the existing import list; if `Data.Name` isn't already imported, add `import qualified Data.Name as Name` alongside the other `qualified` imports near the top of the file.)

- [ ] **Step 2: Render both cases**

In `builder/src/Reporting/Exit.hs`, find the `BP_Cycle` case in `toProjectProblemReport`:

```haskell
    BP_Cycle name names ->
      Help.report "IMPORT CYCLE" Nothing
        "Your module imports form a cycle:"
        [ D.cycle 4 name names
        , D.reflow $
            "Learn more about why this is disallowed and how to break cycles here:"
            ++ D.makeLink "import-cycles"
        ]
```

Add immediately after it:

```haskell
    BP_CycleValue (NE.List (m0, n0) rest) ->
      Help.report "CYCLIC DEFINITION ACROSS MODULES" Nothing
        "These modules depend on each other through a chain of plain (non-function) values, which never terminates:"
        [ D.indent 4 $ D.vcat $
            (D.dullyellow (D.fromName m0) <> "." <> D.fromName n0)
            : map (\(m, n) -> D.dullyellow (D.fromName m) <> "." <> D.fromName n) rest
        , D.reflow $
            "A value defined in terms of itself through other modules has no well-defined\
            \ order to evaluate in. Mutually recursive functions are fine here \8212 only\
            \ plain values (no arguments) are the problem. Try turning one of these into a\
            \ function, or breaking the cycle another way."
        ]

    BP_CycleMissingAnnotation home name ->
      Help.report "ANNOTATION NEEDED FOR CYCLIC IMPORT" Nothing
        "This value is exposed from a module that is part of an import cycle:"
        [ D.indent 4 $ D.dullyellow (D.fromName home) <> "." <> D.fromName name
        , D.reflow $
            "Every value exposed from a module that participates in an import cycle needs\
            \ an explicit type annotation, because I need to know its type before I can\
            \ finish compiling the modules it cycles with. Add a top-level type annotation\
            \ to fix this."
        ]
```

- [ ] **Step 3: Build to confirm it type-checks**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build fails with an incomplete-pattern warning-turned-error on `toProjectProblemReport` only if some other case statement also matches on `BuildProjectProblem` exhaustively elsewhere in the codebase (e.g. JSON encoding of exit codes, if any). Search for this before assuming Step 2 alone is sufficient:

```bash
grep -rn "BP_Cycle\b" builder/src terminal/src
```

If another `case ... of` matches on `BuildProjectProblem` and doesn't have a wildcard branch, add matching arms there too (mirror whatever the existing `BP_Cycle`/`BP_MissingExposed` arms do in that function) before rebuilding.

- [ ] **Step 4: Verify rendering by hand in `cabal repl`**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal repl elm 2>&1 | tail -n 60' <<'EOF'
:m + Reporting.Exit Data.NonEmptyList Data.Name
let p1 = BP_CycleValue (List ("A", "x") [("B", "y")])
let p2 = BP_CycleMissingAnnotation "A" "helper"
:t toProjectProblemReport p1
:t toProjectProblemReport p2
EOF
```

Expected: both `:t` lines succeed and print `Help.Report` (or whatever the actual return type alias resolves to) with no error — confirms both new cases pattern-match and construct a report without runtime error. (`Data.Name`'s string literals need `OverloadedStrings`, already enabled project-wide per `elm.cabal`.)

- [ ] **Step 5: Commit**

```bash
git add builder/src/Reporting/Exit.hs
git commit -m "$(cat <<'EOF'
feat(cycles): add BP_CycleValue / BP_CycleMissingAnnotation error cases

New BuildProjectProblem constructors for the two new failure modes a
restricted cyclic-module SCC can hit: a real cross-module value/CAF
cycle, and an exposed value used across a cycle boundary with no
explicit type annotation. Not yet produced by anything -- Build.hs
still hard-rejects all cycles until the harvest pass (this plan) and
the scheduler rework (a follow-up plan) land.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Generalize the direct-dependency (CAF) cycle detector

**Files:**
- Modify: `compiler/src/Canonicalize/Module.hs`

**Interfaces:**
- Produces: `findValueCycle :: [(key, Can.Def, [key])] -> Maybe (NE.List key)` where `key` is whatever the caller tags each def with (today: just `Name.Name`; Plan 2 will instantiate `key = (ModuleName.Raw, Name.Name)`). This is the exact algorithm `detectBadCycles` already runs, pulled out from `Can.Def`-only shape into a caller-supplied-key shape so it can be reused across module boundaries.
- Consumes: nothing new — this is a pure refactor of existing logic in this file.

Today, `detectBadCycles` operates on `Graph.SCC Can.Def` where the graph nodes are built from `NodeTwo = (Can.Def, Name.Name, [Name.Name])` — the "key" (`Name.Name`) is hardcoded as the second/third tuple slots. Plan 2 needs the same SCC-then-reject-if-cyclic logic, but keyed by `(ModuleName.Raw, Name.Name)` pairs spanning multiple modules, and it needs to happen *after* Pass B (this plan doesn't call it that way — it only extracts and unit-tests the reusable piece).

- [ ] **Step 1: Extract the generic SCC-cycle-check as a new function**

In `compiler/src/Canonicalize/Module.hs`, locate `detectBadCycles`:

```haskell
detectBadCycles :: Graph.SCC Can.Def -> Result i w Can.Def
detectBadCycles scc =
  case scc of
    Graph.AcyclicSCC def ->
      Result.ok def

    Graph.CyclicSCC [] ->
      error "The definition of Data.Graph.SCC should not allow empty CyclicSCC!"

    Graph.CyclicSCC (def:defs) ->
      let
        (A.At region name) = extractDefName def
        names = map (A.toValue . extractDefName) defs
      in
      Result.throw (Error.RecursiveDecl region name names)
```

Add a new, generic function directly above it (keep `detectBadCycles` itself unchanged below — it stays the single-module entry point used by `canonicalizeValues`):

```haskell
-- Generic version of the direct-dependency cycle check `detectBadCycles`
-- performs for one module's own defs, factored out so a caller spanning
-- multiple modules (see Canonicalize.Harvest / the cyclic-modules design)
-- can reuse the exact same "a cyclic SCC among direct dependencies is an
-- error" rule with its own choice of key. `nodes` uses the same shape as
-- `Data.Graph.stronglyConnComp`'s input: (payload, key, direct dep keys).
-- Returns the first offending cycle's keys, if any; the caller decides
-- what to do with a Just (single-module code keeps throwing
-- Error.RecursiveDecl via detectBadCycles below; cross-module code turns
-- it into Exit.BP_CycleValue instead, since it spans multiple modules'
-- source files and can't be rendered as one module's Canonicalize.Error).
findCyclicKeys :: Ord key => [(payload, key, [key])] -> Maybe (NE.List key)
findCyclicKeys nodes =
  findCyclicKeysHelp (Graph.stronglyConnComp nodes)


findCyclicKeysHelp :: [Graph.SCC key] -> Maybe (NE.List key)
findCyclicKeysHelp sccs =
  case sccs of
    [] ->
      Nothing

    Graph.AcyclicSCC _ : otherSccs ->
      findCyclicKeysHelp otherSccs

    Graph.CyclicSCC [] : otherSccs ->
      findCyclicKeysHelp otherSccs

    Graph.CyclicSCC (k:ks) : _ ->
      Just (NE.List k ks)
```

This needs `Ord key` for `Graph.stronglyConnComp`'s internal `Map`-based vertex numbering — check `Data.Graph`'s actual constraint by building (Step 3); if `stronglyConnComp` only requires `Ord` on the key component of each tuple, this is correct as written.

- [ ] **Step 2: Document why `detectBadCycles` doesn't call the new helper**

`detectBadCycles` itself needs no logic change — it keeps its own direct `Graph.CyclicSCC` match rather than routing through `findCyclicKeys`, since it needs the *whole* `Can.Def` payload back (to build `Error.RecursiveDecl`'s region/name), not just keys. Add a one-line comment above it so a future reader doesn't wonder why `findCyclicKeys` looks unused from this function.

In `compiler/src/Canonicalize/Module.hs`, change:

```haskell
detectBadCycles :: Graph.SCC Can.Def -> Result i w Can.Def
detectBadCycles scc =
```

to:

```haskell
-- Single-module entry point (unchanged behavior). See findCyclicKeys
-- above for the cross-module-reusable version of this same rule.
detectBadCycles :: Graph.SCC Can.Def -> Result i w Can.Def
detectBadCycles scc =
```

- [ ] **Step 3: Export `findCyclicKeys` for Task 4's use**

In `compiler/src/Canonicalize/Module.hs`, change the module header:

```haskell
module Canonicalize.Module
  ( canonicalize
  )
  where
```

to:

```haskell
module Canonicalize.Module
  ( canonicalize
  , findCyclicKeys
  )
  where
```

Add the needed import for `NE.List` if not already present — check the existing import list; if `Data.NonEmptyList` isn't imported, add `import qualified Data.NonEmptyList as NE` near the other `qualified` imports.

- [ ] **Step 4: Build to confirm it type-checks and existing behavior is unchanged**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds, no warnings. `findCyclicKeys`/`findCyclicKeysHelp` are unused at this point outside the module, but since `findCyclicKeys` is in the export list, `-Wall` won't flag it (matches the pattern used for `Mode.addLocalArity` in the prior local-arity plan).

- [ ] **Step 5: Regression-check the existing intra-module `RecursiveDecl` error is unchanged**

```bash
mkdir -p /tmp/elm-cycle-harvest/src
cat > /tmp/elm-cycle-harvest/elm.json <<'EOF'
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": { "elm/core": "1.0.5" },
        "indirect": {}
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
EOF
cat > /tmp/elm-cycle-harvest/src/Main.elm <<'EOF'
module Main exposing (main)

x : Int
x = y + 1

y : Int
y = x - 1

main = x
EOF
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v /tmp/elm-cycle-harvest:/test -v elm-cycle-harvest-home:/root/.elm \
  haskell:9.8.4 bash -c 'BIN=$(export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal list-bin elm); cd /test && $BIN make src/Main.elm --output=/dev/null'
```

Expected: fails with `-- CYCLIC DEFINITION --` naming `x` and `y`, byte-identical in wording to what this produced before Task 2's refactor (this is a pure extraction with no behavior change — if the message differs at all, Step 2 introduced a regression and needs to be reverted and redone).

- [ ] **Step 6: Commit**

```bash
git add compiler/src/Canonicalize/Module.hs
git commit -m "$(cat <<'EOF'
refactor(cycles): extract findCyclicKeys from detectBadCycles

Pulls the "run stronglyConnComp, reject if any CyclicSCC survives"
rule out from its Can.Def-specific shape into a caller-keyed generic
version, so cross-module code (Canonicalize.Harvest, this plan; the
Build.hs post-check, a follow-up plan) can reuse the exact same rule
Elm already applies within one module, instead of re-deriving it.
detectBadCycles itself is behaviorally unchanged.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Stub `Interface` construction

**Files:**
- Modify: `compiler/src/Elm/Interface.hs`

**Interfaces:**
- Consumes: `Can.Exports`, `Map.Map Name.Name Can.Union`, `Map.Map Name.Name Can.Alias`, `Map.Map Name.Name Can.Annotation` (partial — only entries for exposed values that had an explicit annotation).
- Produces: `Elm.Interface.fromHarvest :: Pkg.Name -> Can.Exports -> Map.Map Name.Name Can.Union -> Map.Map Name.Name Can.Alias -> Map.Map Name.Name Can.Annotation -> Interface`

This mirrors `fromModule` exactly, minus the two inputs a harvest pass doesn't have yet (a full `Can.Module` and a full-body-inferred `annotations` map) — it takes the already-restricted pieces directly instead of pulling them out of a `Can.Module`.

- [ ] **Step 1: Export the new function**

In `compiler/src/Elm/Interface.hs`, change:

```haskell
module Elm.Interface
  ( Interface(..)
  , Union(..)
  , Alias(..)
  , Binop(..)
  , fromModule
  , toPublicUnion
  , toPublicAlias
  , DependencyInterface(..)
  , public
  , private
  , privatize
  , extractUnion
  , extractAlias
  )
  where
```

to:

```haskell
module Elm.Interface
  ( Interface(..)
  , Union(..)
  , Alias(..)
  , Binop(..)
  , fromModule
  , fromHarvest
  , toPublicUnion
  , toPublicAlias
  , DependencyInterface(..)
  , public
  , private
  , privatize
  , extractUnion
  , extractAlias
  )
  where
```

- [ ] **Step 2: Add `fromHarvest` next to `fromModule`**

In `compiler/src/Elm/Interface.hs`, immediately after `fromModule`'s definition:

```haskell
fromModule :: Pkg.Name -> Can.Module -> Map.Map Name.Name Can.Annotation -> Interface
fromModule home (Can.Module _ exports _ _ unions aliases binops _) annotations =
  Interface
    { _home = home
    , _values = restrict exports annotations
    , _unions = restrictUnions exports unions
    , _aliases = restrictAliases exports aliases
    , _binops = restrict exports (Map.map (toOp annotations) binops)
    }
```

add:

```haskell
-- A stub Interface for a module that's part of a cyclic import SCC and
-- hasn't finished its own compile yet (see the cyclic-modules design
-- doc). Unlike fromModule, there is no finished Can.Module or
-- fully-inferred annotations map to pull from -- only whatever the
-- harvest pass (Canonicalize.Harvest) managed to resolve without
-- needing any SCC peer's full compile to finish first: real, fully
-- resolved unions/aliases, and declared (not inferred) signatures for
-- exposed values that had an explicit annotation. v1 never harvests
-- custom infix operators, so _binops is always empty here.
fromHarvest
  :: Pkg.Name
  -> Can.Exports
  -> Map.Map Name.Name Can.Union
  -> Map.Map Name.Name Can.Alias
  -> Map.Map Name.Name Can.Annotation
  -> Interface
fromHarvest home exports unions aliases annotations =
  Interface
    { _home = home
    , _values = restrict exports annotations
    , _unions = restrictUnions exports unions
    , _aliases = restrictAliases exports aliases
    , _binops = Map.empty
    }
```

- [ ] **Step 3: Build to confirm it type-checks**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds. `fromHarvest` is unused outside this module at this point but is in the export list, so `-Wall` won't flag it.

- [ ] **Step 4: Commit**

```bash
git add compiler/src/Elm/Interface.hs
git commit -m "$(cat <<'EOF'
feat(cycles): add Elm.Interface.fromHarvest stub-interface constructor

Same restrict/restrictUnions/restrictAliases slicing fromModule already
does, but taking already-resolved unions/aliases/signatures directly
instead of pulling them out of a finished Can.Module -- for a cyclic
SCC member that hasn't finished its own compile yet. _binops is always
empty: v1 never harvests custom infix operators across a cycle.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: The harvest pass (`Canonicalize.Harvest`)

> **Note (post-implementation, added after three rounds of code review):**
> Steps 3-6 below are the *original design sketch* and no longer describe
> the shipped code. Review found two rounds of real bugs in the sketch's
> single-pass approach — a module's own placeholder-bodied alias could
> leak into a peer's resolved type body (and, more subtly, into a
> harvested union's own constructor argument), because nothing guaranteed
> alias-before-alias resolution order across the whole SCC. The shipped
> `compiler/src/Canonicalize/Harvest.hs` restructures type-body resolution
> into two explicit phases instead: Phase A (`resolveAliasesInOrder`)
> resolves every SCC alias's real body one at a time, in true cross-module
> topological dependency order (reusing `Graph.stronglyConnComp` over the
> same edge set the alias-cycle check already computes), folding each
> result into a running snapshot before the next alias resolves — a direct
> generalization of `Canonicalize/Environment/Local.hs`'s own
> `addAliases`/`addAlias`. Only once every alias has a real body does
> Phase B (`resolveUnions`) resolve every union in one pass. A single
> shared function, `withSccTypes` (parameterized by which alias-body
> snapshot is available), replaces the sketch's separate
> `addOwnTypes`/`addPeerImport`/`shapeToType` injection functions. `harvest`
> also returns `Either Failure (...)` (not the `Result i w (...)` shown in
> the Produces line below), and exports `Restriction(..)` alongside
> `Failure(..)` (a v1 restriction check, rejecting ports/effect
> managers/custom infix operators in any cyclic-SCC module, that isn't in
> the sketch below at all). **Treat the actual `Harvest.hs` source as the
> source of truth for this task's design** — Steps 3-6's code blocks are
> useful for understanding the original intent and the single-module
> patterns they're generalizing from, but do not reflect what's on `main`.
> See `.superpowers/sdd/task-4-report.md` (gitignored, worktree-local) for
> the full history across all three review rounds if you need it.

**Files:**
- Create: `compiler/src/Canonicalize/Harvest.hs`
- Modify: `elm.cabal` (register the new module)

**Interfaces:**
- Consumes: `Foreign.createInitialEnv` (unchanged), `Local.addTypes`/`Local.addAliases`-equivalent logic (reimplemented here spanning multiple `home`s — `Local.add` itself can't be reused as-is since it hardcodes a single `home`), `Canonicalize.Module.canonicalizeExports` (unchanged, reused directly), `Elm.Interface.fromHarvest` (Task 3), `Type.toAnnotation` (unchanged).
- Produces: `Harvest.harvest :: Pkg.Name -> Map.Map ModuleName.Raw I.Interface -> Map.Map ModuleName.Raw Src.Module -> Result i w (Map.Map ModuleName.Raw I.Interface)` — given the real interfaces for everything *outside* the SCC and the parsed `Src.Module` for every module *inside* the SCC, produces one stub `Interface` per SCC member, or a `Canonicalize.Error`-shaped failure (missing annotation / alias cycle — see below on why these are still `Canonicalize.Error` here even though Task 1's `Exit`-level errors exist for them; Plan 2 reconciles this).

**A note on error types before writing code:** Task 1 added `Exit.BP_CycleMissingAnnotation`, a `BuildProjectProblem`. But `Canonicalize.Error` (what `Result i w Error.Error a` throws) is scoped to *one* module's source — it can't reference a peer module's declaration the way a `BuildProjectProblem` can. `harvest` operates over several modules' `Src.Module`s at once, so its own missing-annotation/alias-cycle detection should report failures directly as data (`Either` a small new failure type, not `Canonicalize.Error`), and Plan 2's `Build.hs` wiring translates that failure into `Exit.BP_CycleMissingAnnotation` before returning it as a `BuildProjectProblem`. This plan therefore does *not* reuse the `Result i w Error.Error a` monad from the rest of `Canonicalize.*` for `harvest`'s own top-level checks — only for the pieces it calls into (`Type.toAnnotation`, `Local`-style union/alias resolution, `canonicalizeExports`), which still throw `Canonicalize.Error` for reasons unrelated to cycles (e.g. a genuinely malformed type in a signature) and get threaded through unchanged.

- [ ] **Step 1: Define the module skeleton and failure type**

Create `compiler/src/Canonicalize/Harvest.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module Canonicalize.Harvest
  ( Failure(..)
  , harvest
  )
  where


import Control.Monad (foldM)
import qualified Data.Graph as Graph
import qualified Data.Map.Strict as Map
import qualified Data.Name as Name

import qualified AST.Canonical as Can
import qualified AST.Source as Src
import qualified Canonicalize.Environment as Env
import qualified Canonicalize.Environment.Foreign as Foreign
import qualified Canonicalize.Module as CModule
import qualified Canonicalize.Type as Type
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as CError
import qualified Reporting.Result as Result


-- FAILURE
--
-- harvest's own cycle-shaped checks are reported as plain data, not
-- Canonicalize.Error, since they span multiple modules and
-- Canonicalize.Error is scoped to rendering against one module's
-- source. The caller (Build.hs, in a follow-up plan) turns these into
-- Exit.BP_CycleMissingAnnotation / a type-alias-cycle equivalent;
-- CanonicalizeError below is for genuinely per-module problems (a
-- malformed signature, an unbound type variable, etc.) surfaced while
-- resolving one member's types/signatures, which do render against
-- that one member's own source the normal way.
data Failure
  = MissingAnnotation ModuleName.Raw Name.Name
  | AliasCycle (ModuleName.Raw, Name.Name) [(ModuleName.Raw, Name.Name)]
  | CanonicalizeError ModuleName.Raw CError.Error
```

- [ ] **Step 2: Register every SCC member's union/alias name+arity across the whole SCC**

Add to `compiler/src/Canonicalize/Harvest.hs`. This mirrors `Local.addTypes`'s `addUnion` step (register name+arity, no bodies yet) but folds over every SCC member's declarations, tagging each with its owning module's `home` so `Type.canonicalize` resolves a peer's type reference (`B.Bar`) to the right module. `Env.Env` is single-`home`, so this builds one *shared* `_types`/`_ctors`-free registration table keyed by `(ModuleName.Raw, Name.Name)`, consulted when building each member's own env in Step 3 — not by mutating a shared `Env.Env` directly.

```haskell
-- Registration table: every SCC member's own union/alias name, arity,
-- and owning module -- built with no bodies resolved yet, exactly like
-- Local.addTypes registers a module's own type names before resolving
-- any of them. Aliases are also registered here (for arity/lookup
-- purposes) even though a *cyclic* alias is always rejected in Step 4
-- -- an acyclic alias that merely lives in a cyclic-SCC module (e.g.
-- `type alias Pair = (A.Foo, Int)` where only Foo, not Pair, is part of
-- the cycle) is completely fine and still needs registering here.
data TypeShape
  = ShapeUnion Int
  | ShapeAlias Int

type Registry = Map.Map (ModuleName.Raw, Name.Name) TypeShape


registerTypes :: Map.Map ModuleName.Raw Src.Module -> Registry
registerTypes modules =
  Map.foldrWithKey addModule Map.empty modules
  where
    addModule modName (Src.Module _ _ _ _ _ unions aliases _ _) registry =
      let
        addUnion r (A.At _ (Src.Union (A.At _ name) args _)) =
          Map.insert (modName, name) (ShapeUnion (length args)) r
        addAlias r (A.At _ (Src.Alias (A.At _ name) args _)) =
          Map.insert (modName, name) (ShapeAlias (length args)) r
      in
      foldl addAlias (foldl addUnion registry unions) aliases
```

- [ ] **Step 3: Build each SCC member's env and resolve union/alias bodies**

Add:

```haskell
-- Build one SCC member's Env for resolving its own union/alias bodies
-- and signatures: real Foreign.createInitialEnv for its outside-the-SCC
-- imports, plus direct insertion of every *other* SCC member's
-- registered (name, arity) as if they were foreign bindings too. This
-- is deliberately not routed through Foreign.createInitialEnv for SCC
-- peers -- that function requires a real, finished I.Interface (real
-- Can.Union/Can.Alias values, since it also builds constructor
-- bindings), which peers don't have yet at registration time.
buildEnv
  :: Registry
  -> Map.Map ModuleName.Raw I.Interface
  -> ModuleName.Raw
  -> Src.Module
  -> Result.Result i w CError.Error Env.Env
buildEnv registry outsideIfaces modName (Src.Module _ _ _ imports _ _ _ _ _) =
  let
    home = ModuleName.Canonical Pkg.dummyName modName
    -- imports naming a fellow SCC member won't be found in
    -- outsideIfaces; Foreign.createInitialEnv indexes ifaces with (!),
    -- so those imports must be filtered out before calling it, then
    -- reinjected via addPeerTypes below.
    isPeerImport (Src.Import (A.At _ n) _ _) = n /= modName && any (\(m,_) -> m == n) (Map.keys registry)
    outsideImports = filter (not . isPeerImport) imports
  in
  do  env <- Foreign.createInitialEnv home outsideIfaces outsideImports
      Result.ok (foldr (addPeerImport registry) env (filter isPeerImport imports))


addPeerImport :: Registry -> Src.Import -> Env.Env -> Env.Env
addPeerImport registry (Src.Import (A.At _ peerName) maybeAlias _) env@(Env.Env home vs ts cs bs qvs qts qcs) =
  let
    prefix = maybe peerName id maybeAlias
    peerHome = ModuleName.Canonical Pkg.dummyName peerName
    peerTypes =
      Map.fromList
        [ (name, Env.Specific peerHome (shapeToType peerHome shape))
        | ((m, name), shape) <- Map.toList registry
        , m == peerName
        ]
    shapeToType h shape =
      case shape of
        ShapeUnion arity -> Env.Union arity h
        ShapeAlias arity -> Env.Alias arity h [] (Can.TVar "harvestPlaceholder")
        -- NOTE: Env.Alias's args/tipe fields are only consulted when a
        -- *use site* expands the alias (Type.canonicalize's alias-arg
        -- substitution). At registration time nothing should be
        -- expanding a peer alias yet -- Step 4 resolves real alias
        -- bodies before anything downstream can reference them for
        -- expansion. If this placeholder is ever actually read, that's
        -- a genuine bug in the ordering, not something to silently
        -- tolerate -- flag it during Step 6/7 verification if seen.
  in
  Env.Env home vs (Map.union peerTypes ts) cs bs qvs (Map.insertWith (\_ old -> old) prefix peerTypes qts) qcs
```

- [ ] **Step 4: Export reusable body-resolution helpers from `Local.hs`**

`Canonicalize/Environment/Local.hs` already has exactly the per-declaration logic needed to resolve a union/alias body (`canonicalizeUnion`, `canonicalizeAlias`) — both take an `Env.Env` and a single declaration and don't assume anything about *which* module owns the env, so they work unchanged for a harvested SCC member's env from Step 3. Only their exports are missing.

In `compiler/src/Canonicalize/Environment/Local.hs`, change:

```haskell
module Canonicalize.Environment.Local
  ( add
  )
  where
```

to:

```haskell
module Canonicalize.Environment.Local
  ( add
  , canonicalizeUnion
  , canonicalizeAlias
  )
  where
```

(`canonicalizeUnion`/`canonicalizeAlias` each return `Result i w ((Name.Name, Can.Union/Alias), CtorDups)` — `CtorDups` is for detecting a ctor name colliding with another ctor *in the same module*, which stays a per-module concern unaffected by harvesting, so `Harvest.hs` calls these and discards the `CtorDups` half of the result.)

- [ ] **Step 5: Implement `resolveTypeBodies`**

Add to `compiler/src/Canonicalize/Harvest.hs`. This is a cross-module generalization of `Local.hs`'s `addAliases`/`toNode`/`getEdges` (alias-cycle detection) followed by `addCtors`'s per-declaration resolution (reusing the newly-exported `canonicalizeUnion`/`canonicalizeAlias` directly, per Step 4):

```haskell
-- Resolve every SCC member's real union/alias bodies, using the envs
-- from Step 3 (which can already see every peer's registered
-- name+arity). Rejects a type-alias cycle across the SCC boundary
-- first, the same way Local.addAliases rejects one within a single
-- module -- generalized from Name.Name keys to (ModuleName.Raw,
-- Name.Name) keys spanning every SCC member's aliases at once.
resolveTypeBodies
  :: Registry
  -> Map.Map ModuleName.Raw Env.Env
  -> Map.Map ModuleName.Raw Src.Module
  -> Either Failure (Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias))
resolveTypeBodies registry envs modules =
  case CModule.findCyclicKeys (aliasNodes registry modules) of
    Just (NE.List key keys) ->
      Left (AliasCycle key keys)

    Nothing ->
      Map.traverseWithKey (resolveOneModule envs) modules


resolveOneModule
  :: Map.Map ModuleName.Raw Env.Env
  -> ModuleName.Raw
  -> Src.Module
  -> Either Failure (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias)
resolveOneModule envs modName (Src.Module _ _ _ _ _ unions aliases _ _) =
  do  let env = envs Map.! modName
      unionList <- traverse (resolveDecl modName (fmap fst . Local.canonicalizeUnion env)) unions
      aliasList <- traverse (resolveDecl modName (fmap fst . Local.canonicalizeAlias env)) aliases
      Right (Map.fromList unionList, Map.fromList aliasList)


resolveDecl :: ModuleName.Raw -> (decl -> Result.Result i w CError.Error a) -> decl -> Either Failure a
resolveDecl modName resolver decl =
  case resultToEither (resolver decl) of
    Left err -> Left (CanonicalizeError modName err)
    Right a  -> Right a


-- One SCC-wide alias dependency graph, generalizing Local.hs's
-- toNode/getEdges from same-module-only edges to edges that can point
-- at a fellow SCC member too. TType is an unqualified reference (could
-- be same-module); TTypeQual is a `Prefix.Name` qualified reference,
-- resolved back to a real module via that module's own import list
-- (importAliases). Either way, an edge is only recorded if it actually
-- lands on a name in `registry` -- anything else (a builtin, an
-- outside-the-SCC import) is irrelevant to whether *this* SCC has a
-- cycle and is silently ignored, exactly like Local.hs's getEdges
-- ignores non-local names today.
aliasNodes
  :: Registry
  -> Map.Map ModuleName.Raw Src.Module
  -> [(A.Located Src.Alias, (ModuleName.Raw, Name.Name), [(ModuleName.Raw, Name.Name)])]
aliasNodes registry modules =
  concatMap toNodes (Map.toList modules)
  where
    toNodes (modName, modul@(Src.Module _ _ _ _ _ _ aliases _ _)) =
      let prefixes = importAliases modul in
      [ ( alias
        , (modName, name)
        , getEdgesAcrossModules registry prefixes modName [] tipe
        )
      | alias@(A.At _ (Src.Alias (A.At _ name) _ tipe)) <- aliases
      ]


importAliases :: Src.Module -> Map.Map Name.Name ModuleName.Raw
importAliases (Src.Module _ _ _ imports _ _ _ _ _) =
  Map.fromList [ (maybe name id maybeAlias, name) | Src.Import (A.At _ name) maybeAlias _ <- imports ]


getEdgesAcrossModules
  :: Registry
  -> Map.Map Name.Name ModuleName.Raw
  -> ModuleName.Raw
  -> [(ModuleName.Raw, Name.Name)]
  -> Src.Type
  -> [(ModuleName.Raw, Name.Name)]
getEdgesAcrossModules registry prefixes home edges (A.At _ tipe) =
  let recur = getEdgesAcrossModules registry prefixes home in
  case tipe of
    Src.TLambda arg result ->
      recur (recur edges arg) result

    Src.TVar _ ->
      edges

    Src.TType _ name args ->
      let edges1 = if Map.member (home, name) registry then (home, name) : edges else edges in
      List.foldl' recur edges1 args

    Src.TTypeQual _ prefix name args ->
      let
        edges1 =
          case Map.lookup prefix prefixes of
            Just modName | Map.member (modName, name) registry -> (modName, name) : edges
            _ -> edges
      in
      List.foldl' recur edges1 args

    Src.TRecord fields _ ->
      List.foldl' (\es (_,t) -> recur es t) edges fields

    Src.TUnit ->
      edges

    Src.TTuple a b cs ->
      List.foldl' recur (recur (recur edges a) b) cs
```

This needs two more imports at the top of `compiler/src/Canonicalize/Harvest.hs` (from Step 1): `import qualified Data.List as List`, `import qualified Data.NonEmptyList as NE`, and `import qualified Canonicalize.Environment.Local as Local`.

- [ ] **Step 6: Tie it together — `harvest`, and resolve declared signatures**

Add to `compiler/src/Canonicalize/Harvest.hs`:

```haskell
harvest
  :: Pkg.Name
  -> Map.Map ModuleName.Raw I.Interface
  -> Map.Map ModuleName.Raw Src.Module
  -> Either Failure (Map.Map ModuleName.Raw I.Interface)
harvest pkg outsideIfaces modules =
  do  let registry = registerTypes modules
      envs <- Map.traverseWithKey (buildEnvFor registry outsideIfaces) modules
      typeBodies <- resolveTypeBodies registry envs modules
      Map.traverseWithKey (harvestOne pkg envs typeBodies) modules


buildEnvFor
  :: Registry
  -> Map.Map ModuleName.Raw I.Interface
  -> ModuleName.Raw
  -> Src.Module
  -> Either Failure Env.Env
buildEnvFor registry outsideIfaces modName modul =
  resolveDecl modName (const (buildEnv registry outsideIfaces modName modul)) ()


harvestOne
  :: Pkg.Name
  -> Map.Map ModuleName.Raw Env.Env
  -> Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias)
  -> ModuleName.Raw
  -> Src.Module
  -> Either Failure I.Interface
harvestOne pkg envs typeBodies modName modul@(Src.Module _ exports _ _ values _ _ _ _) =
  do  let env = envs Map.! modName
      let (unions, aliases) = typeBodies Map.! modName
      annotations <- foldM (harvestSignature modName env) Map.empty values
      cexports <- either (Left . CanonicalizeError modName) Right $
        resultToEither (CModule.canonicalizeExports values unions aliases Map.empty Can.NoEffects exports)
      Right (I.fromHarvest pkg cexports unions aliases annotations)


harvestSignature
  :: ModuleName.Raw
  -> Env.Env
  -> Map.Map Name.Name Can.Annotation
  -> A.Located Src.Value
  -> Either Failure (Map.Map Name.Name Can.Annotation)
harvestSignature modName env acc (A.At _ (Src.Value (A.At _ name) _ _ maybeType)) =
  case maybeType of
    Nothing ->
      -- v1 restriction: every value is required to carry an explicit
      -- annotation while its module is part of a cyclic SCC, whether
      -- or not it's actually exposed -- see this plan's header for why
      -- (simpler than a precise "exposed AND referenced cross-module"
      -- check). The exposed-only check happens naturally at the
      -- Interface-restriction step (I.fromHarvest / `restrict`): an
      -- unexposed value missing here just never surfaces to peers.
      -- Reject eagerly anyway so the error points at the actual
      -- missing annotation instead of a confusing later "not found".
      Left (MissingAnnotation modName name)

    Just srcType ->
      case resultToEither (Type.toAnnotation env srcType) of
        Left err   -> Left (CanonicalizeError modName err)
        Right ann  -> Right (Map.insert name ann acc)


-- Result.run's real signature (Reporting/Result.hs:32) is
-- `Result () [w] e a -> ([w], Either (OneOrMore.OneOrMore e) a)` --
-- confirmed by reading it directly, and matches how Compile.hs's own
-- `canonicalize` consumes Canonicalize.Module.canonicalize's result
-- (`Error.BadNames (OneOrMore.OneOrMore Canonicalize.Error)`). The
-- Left case is a *nonempty bag* of errors, not a single one -- reduce
-- to one representative error via OneOrMore.destruct (first wins),
-- consistent with how findCyclicKeys/AliasCycle above already report
-- only the first offending thing found rather than everything at once.
resultToEither :: Result.Result () [w] e a -> Either e a
resultToEither result =
  case snd (Result.run result) of
    Right a -> Right a
    Left oneOrMore -> Left (OneOrMore.destruct (\e _ -> e) oneOrMore)
```

This needs one more import at the top of `compiler/src/Canonicalize/Harvest.hs` (from Step 1): `import qualified Data.OneOrMore as OneOrMore`.

(Since `resultToEither`'s type now fixes `Result.Result`'s first two parameters to `()`/`[w]` to match `Result.run`, double-check every call site — `Type.toAnnotation`, `Local.canonicalizeUnion`, `Local.canonicalizeAlias`, `CModule.canonicalizeExports` — actually produces a `Result () [w] CError.Error a` shape and not some other `i`/`w` instantiation; if any of them come back typed as `Result i w CError.Error a` with `i`/`w` left polymorphic rather than concretely `()`/`[SomethingList]`, GHC will unify them against `resultToEither`'s now-concrete signature automatically as long as nothing else pins `i`/`w` to something incompatible first — flag it here if that's not the case once this actually compiles.)

- [ ] **Step 7: Register the new module in `elm.cabal` and build**

In `elm.cabal`, find the `exposed-modules` or `other-modules` list containing `Canonicalize.Module` (in the `compiler` library stanza) and add `Canonicalize.Harvest` alongside it, alphabetically ordered with its neighbors (matching this file's existing convention — check a few surrounding entries to confirm ordering style before inserting).

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 200; exit ${PIPESTATUS[0]}'
```

Expected: **this will not succeed on the first try.** Work through GHC's errors in order — likely candidates, roughly in the order they'll probably surface: `Env.Env`'s actual field/constructor arity in `addPeerImport` (re-check against `Canonicalize/Environment.hs`'s real `data Env` definition and its `Var`/`Type`/`Info` constructors if the pattern match doesn't line up), `Result.run`'s real signature (Step 6's note above), whether `Map.!` needs `Data.Map.Strict`'s `(!)` import explicitly, and `-Wall`'s unused-binding complaints in `registerTypes` (Step 2's explicit callout) and anywhere else a drafted-but-unused helper slipped in. Fix each in turn and rebuild; do not move to Step 8 until this builds clean with zero warnings.

- [ ] **Step 8: Verify `harvest` against a synthetic 3-module SCC via `cabal repl`**

This is this plan's actual correctness test, standing in for the `elm make`-against-a-scratch-project verification used elsewhere in this repo — `Build.hs` doesn't call any of this yet, so there is no `elm make` path to exercise.

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal repl elm 2>&1 | tail -n 100' <<'EOF'
:m + Canonicalize.Harvest Parse.Module Data.Map.Strict Elm.Package
import qualified Data.ByteString.Char8 as BS8
let srcA = BS8.pack "module A exposing (Expr(..), isZero)\n\nimport B\n\ntype Expr = Lit Int | Neg B.Stmt\n\nisZero : Expr -> Bool\nisZero e =\n  case e of\n    Lit 0 -> True\n    _ -> False\n"
let srcB = BS8.pack "module B exposing (Stmt(..))\n\nimport A\n\ntype Stmt = Run A.Expr\n"
let (Right modA) = Parse.fromByteString Parse.Application srcA
let (Right modB) = Parse.fromByteString Parse.Application srcB
let modules = fromList [("A", modA), ("B", modB)]
let result = harvest Elm.Package.dummyName Data.Map.Strict.empty modules
case result of { Left f -> print f ; Right ifaces -> mapM_ print (Data.Map.Strict.toList ifaces) }
EOF
```

Expected: `Right`, printing two `Interface` values — `A`'s with `_unions` containing `Expr` (ctor `Lit`/`Neg`, the latter's argument referencing `B.Stmt`) and `_values` containing `isZero`'s annotation; `B`'s with `_unions` containing `Stmt` (ctor `Run`, argument referencing `A.Expr`). If this instead prints `Left (CanonicalizeError ...)` or `Left (MissingAnnotation ...)`, something in Steps 2-6 has a bug — this exact scenario (mutually recursive unions, one annotated cross-referenced function) is the minimal positive case the whole plan exists to make work, so do not consider Task 4 done until this specific `repl` session prints `Right` with both interfaces populated as described.

- [ ] **Step 9: Verify the two rejection paths**

Same `cabal repl` session shape as Step 8, with two more scenarios:

*Missing annotation:* change `isZero`'s definition in `srcA` to drop its `Expr -> Bool` signature line (keep `isZero e = case e of ...` unsigned). Expected: `Left (MissingAnnotation "A" "isZero")`.

*Alias cycle:* replace both modules' `type` with `type alias`: `srcA = "module A exposing (Expr)\n\nimport B\n\ntype alias Expr = B.Stmt\n"`, `srcB = "module B exposing (Stmt)\n\nimport A\n\ntype alias Stmt = A.Expr\n"`. Expected: `Left (AliasCycle ("A","Expr") [("B","Stmt")])` (or the reverse order/starting element — exact SCC traversal order isn't the point, just that it's `Left (AliasCycle ...)` naming both).

If either produces something else (in particular, if the alias-cycle case is instead accepted, silently producing an infinite-expansion `Can.Alias` — the single worst possible outcome here, since it would compile successfully and only blow up later, possibly as a GHC stack overflow inside `elm`, not a clean user-facing error), stop and revisit Step 5's port before proceeding.

- [ ] **Step 10: Commit**

```bash
git add compiler/src/Canonicalize/Harvest.hs elm.cabal
git commit -m "$(cat <<'EOF'
feat(cycles): add Canonicalize.Harvest, the cross-module cycle resolver

harvest resolves a cyclic SCC's mutually recursive `type` (union)
declarations and every exposed value's explicit annotation into one
stub Interface per module, without needing any SCC member's own full
compile to finish first. Two v1 restrictions enforced here: every
value is required to carry an explicit annotation while its module is
part of a cycle, and `type alias` cycles across the SCC boundary are
rejected the same way an intra-module alias cycle already is.

Not yet wired into Build.hs -- verified standalone in this commit via
a cabal repl session against synthetic multi-module input (see
docs/superpowers/plans/2026-07-07-cyclic-modules-plan1-harvest.md,
Task 4, Steps 8-9). Wiring this into the live build scheduler without
deadlocking its MVar-based concurrent compile scheme is a separate,
follow-up plan.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 11: Clean up scratch state**

```bash
rm -rf /tmp/elm-cycle-harvest
docker volume rm elm-cycle-harvest-home
```

---

## What Plan 2 picks up from here

- Extract cyclic SCCs in `Build.hs`'s crawl phase (today: `checkForCycles` at `Build.hs:614-633` unconditionally fails; needs to instead partition modules into "normal" vs. "member of an admissible cyclic SCC").
- Pull cyclic-SCC members out of the per-module `forkWithKey (checkModule ...)` scheme (`Build.hs:159,214`) — their mutual `readMVar` reads on each other's results would deadlock — and drive them through this plan's `Harvest.harvest` (Pass A) followed by real `Compile.compile` calls fed the harvested stubs (Pass B), sequenced directly by the SCC-handling code rather than by blocking on peer MVars.
- After Pass B, run `Canonicalize.Module.findCyclicKeys` (Task 2) over the whole SCC's real `Can.Def`s (keyed by `(ModuleName.Raw, Name.Name)`, direct-dependency edges only, argument-less defs only — mirroring `toNodeTwo`'s existing "has args ⇒ no direct edges" rule) and turn a hit into `Exit.BP_CycleValue` (Task 1).
- Translate `Harvest.Failure`'s `MissingAnnotation`/`AliasCycle` cases into `Exit.BP_CycleMissingAnnotation` / an alias-cycle equivalent (Task 1 only added the value-cycle and missing-annotation constructors — an `Exit.BP_CycleAlias`-shaped constructor following the same pattern is Plan 2's addition, once the exact reporting shape needed is clearer from wiring it up for real).
- The interface-cache atomicity concern from the design doc (a cyclic SCC must invalidate/recompile as one unit, not per-module) — entirely unaddressed by this plan, since this plan never writes anything to `Stuff.elmi`/`Stuff.elmo`.
