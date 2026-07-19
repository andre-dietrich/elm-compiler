# List Pipeline Fusion V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the V1 list-pipeline-fusion pass (`main @ 6dac555d`) with two additive capabilities:
(A) `List.sum`/`List.length`/`List.product` as fusable terminal consumers, alongside the existing
`List.foldl`; (B) `List.filterMap` as a fusable producer stage, alongside the existing `List.map`/
`List.filter`. Both eliminate the same class of intermediate-list allocation/traversal V1 already
eliminates for `foldl`-terminated `map`/`filter` chains.

**Architecture:** Same file, same integration point as V1 — `Optimize.Expression.hs`'s `optimize`
function. Extension A factors V1's foldl-call-construction tail into a shared `buildFusedFold` helper
reused by four terminator triggers instead of one. Extension B adds a new `ListStage` constructor
whose `wrapStage` case synthesizes a `Just`/`Nothing` pattern match via the *existing*
`Optimize.Case`/`Optimize.DecisionTree` compiler (the same machinery any hand-written `case x of Just
y -> ..; Nothing -> ..` already goes through), not a hand-rolled ctor-tag test. No new
`AST.Optimized` constructor, no `.elmo`/binary format change — both extensions produce ordinary
`Opt.Call`/`Opt.Case` nodes already in the format.

**Tech Stack:** Haskell (GHC 9.8.4 via the project's Docker toolchain).

## Global Constraints

- Build with `-Wall -Werror` (baked into `elm.cabal`) — any unused import/bind fails the build.
- No `.elmo`/`.elmi` binary format change — must not touch `AST.Optimized`'s `Data.Binary` instances.
- Not `Mode`-gated (runs identically in Dev and Prod), matching V1/TRMC/prim-binop-specialization.
- Full design rationale, correctness argument, and scope boundaries:
  `docs/superpowers/specs/2026-07-19-list-fusion-v2-design.md`.
- Fusion only fires on **direct syntactic** `List.sum`/`List.length`/`List.product`/`List.filterMap`
  calls (any import style — qualified, aliased, exposed — all canonicalize to the same identity, same
  as V1). Does **not** fire through a local alias; that call site is simply left unoptimized, never
  miscompiled.
- Both extensions are purely additive: no change to V1's existing `foldl`/`map`/`filter` fusion
  behavior. If any V1 regression is observed during verification, stop and investigate before
  proceeding — it means a shared helper (`collectApplication`/`peelChain`/`wrapStage`) was changed
  incorrectly, not that V2 is inherently risky to V1.

---

### Task 1: `List.sum`/`List.length`/`List.product` terminators

**Files:**
- Modify: `compiler/src/Optimize/Expression.hs:61-79` (the single `foldl`-only guarded alternative)
- Modify: `compiler/src/Optimize/Expression.hs` (insert new helpers after `wrapStage`, i.e. after the
  line currently reading `pure (Opt.If [(Opt.Call optP [elemExpr], thenBranch)] accExpr)` that closes
  `wrapStage`'s `StageFilter` case, before the comment block `-- Does this list of arguments contain
  exactly one direct self-call...`)

**Interfaces:**
- Consumes: `StepK`, `baseStepK`, `wrapStage`, `peelChain`, `ListStage` (all already defined further
  down this same file, forward-referenced exactly as V1's original case alternative already does),
  `Names.registerGlobal`, `ModuleName.list`/`ModuleName.basics` (already imported).
- Produces: `buildFusedFold :: Hints -> Cycle -> StepK -> Opt.Expr -> [ListStage] -> Can.Expr ->
  Names.Tracker Opt.Expr` and `baseStepKLength :: Opt.Expr -> StepK`, both consumed only within this
  same file (no other module imports `Optimize.Expression`'s internals — its export list is `optimize,
  Hints, destructArgs, optimizePotentialTailCall` only, unchanged by this task).

- [ ] **Step 1: Add `buildFusedFold` and `baseStepKLength` after `wrapStage`**

Insert directly after `wrapStage`'s definition (after the `StageFilter` case's closing line):

```haskell
-- Shared tail of every fusion trigger below (foldl/sum/product/length):
-- given a base step continuation and an initial accumulator value already
-- as Opt.Expr, peels/composes `stages` over `source` and emits one
-- ordinary List.foldl call. `initExpr` is Opt.Int 0/1 for sum/length/
-- product's implicit init, or the user's own already-`optimize`'d acc
-- argument for foldl.
buildFusedFold :: Hints -> Cycle -> StepK -> Opt.Expr -> [ListStage] -> Can.Expr -> Names.Tracker Opt.Expr
buildFusedFold hints cycle base initExpr stages source =
  do  optSource <- optimize hints cycle source
      composed  <- foldM (wrapStage hints cycle) base stages
      xName     <- Names.generate
      accName   <- Names.generate
      body      <- composed (Opt.VarLocal xName) (Opt.VarLocal accName)
      optFoldl  <- Names.registerGlobal ModuleName.list "foldl"
      pure $ Opt.Call optFoldl
        [ Opt.Function [xName, accName] body
        , initExpr
        , optSource
        ]


-- length's implicit step ignores the element entirely (`\_ i -> i + 1`),
-- unlike baseStepK which calls a real user-supplied 2-arg step function —
-- needs its own base continuation rather than reusing baseStepK with a
-- synthesized lambda.
baseStepKLength :: Opt.Expr -> StepK
baseStepKLength optAdd _ accExpr =
  pure (Opt.Call optAdd [accExpr, Opt.Int 1])
```

- [ ] **Step 2: Replace the single `foldl` guarded alternative with four terminator alternatives**

Current code at `compiler/src/Optimize/Expression.hs:61-79`:

```haskell
    _
      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "foldl"
      , [stepArg, accArg, listArg] <- args
      , (stages@(_:_), source) <- peelChain listArg
      ->
          do  optStep    <- optimize hints cycle stepArg
              optAcc     <- optimize hints cycle accArg
              optSource  <- optimize hints cycle source
              composed   <- foldM (wrapStage hints cycle) (baseStepK optStep) stages
              xName      <- Names.generate
              accName    <- Names.generate
              body       <- composed (Opt.VarLocal xName) (Opt.VarLocal accName)
              optFoldl   <- Names.registerGlobal ModuleName.list "foldl"
              pure $ Opt.Call optFoldl
                [ Opt.Function [xName, accName] body
                , optAcc
                , optSource
                ]
```

Replace with:

```haskell
    _
      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "foldl"
      , [stepArg, accArg, listArg] <- args
      , (stages@(_:_), source) <- peelChain listArg
      ->
          do  optStep <- optimize hints cycle stepArg
              optAcc  <- optimize hints cycle accArg
              buildFusedFold hints cycle (baseStepK optStep) optAcc stages source

      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "sum"
      , [listArg] <- args
      , (stages@(_:_), source) <- peelChain listArg
      ->
          do  optAdd <- Names.registerGlobal ModuleName.basics "add"
              buildFusedFold hints cycle (baseStepK optAdd) (Opt.Int 0) stages source

      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "product"
      , [listArg] <- args
      , (stages@(_:_), source) <- peelChain listArg
      ->
          do  optMul <- Names.registerGlobal ModuleName.basics "mul"
              buildFusedFold hints cycle (baseStepK optMul) (Opt.Int 1) stages source

      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "length"
      , [listArg] <- args
      , (stages@(_:_), source) <- peelChain listArg
      ->
          do  optAdd <- Names.registerGlobal ModuleName.basics "add"
              buildFusedFold hints cycle (baseStepKLength optAdd) (Opt.Int 0) stages source
```

(Four guarded bodies under one `_` case alternative — standard Haskell guarded-alternative syntax,
already relied on by V1's single-guard version; adding more `|`-guards to the same alternative doesn't
change that.)

- [ ] **Step 3: Build the compiler and confirm it compiles clean under `-Wall -Werror`**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds (exit code 0), no warnings/errors mentioning `Optimize/Expression.hs`.

- [ ] **Step 4: Commit**

```bash
git add compiler/src/Optimize/Expression.hs
git commit -m "perf: fuse map/filter producer chains into sum/length/product terminators"
```

---

### Task 2: `List.filterMap` producer stage

**Files:**
- Modify: `compiler/src/Optimize/Expression.hs` (`ListStage` data type, `peelListStage`, `stageInner`,
  `wrapStage` — all in the "LIST PIPELINE FUSION" section added by V1, currently lines ~523-628; exact
  line numbers will have shifted after Task 1's edits, locate by the section comment
  `-- LIST PIPELINE FUSION (map/filter -> foldl)`)

**Interfaces:**
- Consumes: `destructCase :: Name.Name -> Can.Pattern -> Names.Tracker [Opt.Destructor]` (already
  defined in this file, line 382 before Task 1's edits), `Optimize.Case.optimize :: Name.Name ->
  Name.Name -> [(Can.Pattern, Opt.Expr)] -> Opt.Expr` (already imported as `Case.optimize`, pure
  function — not `Names.Tracker`-monadic, unlike everything else in this pass), `Index.first`/
  `Index.second` (`Data.Index`, already imported as `Index`), `A.zero`/`A.At` (`Reporting.Annotation`,
  already imported as `A`), `ModuleName.maybe` (`Elm.ModuleName`, already imported as `ModuleName`),
  `Name.maybe` (`Data.Name`, already imported as `Name`). No new imports needed anywhere in this task
  — verified by reading the file's existing import list.
- Produces: nothing consumed by later tasks in this plan — Task 3 only builds and runs the resulting
  binary.

- [ ] **Step 1: Add `StageFilterMap` to `ListStage`**

Current (V1):

```haskell
data ListStage
  = StageMap Can.Expr Can.Expr     -- f, inner list expr
  | StageFilter Can.Expr Can.Expr  -- p, inner list expr
```

Replace with:

```haskell
data ListStage
  = StageMap Can.Expr Can.Expr        -- f, inner list expr
  | StageFilter Can.Expr Can.Expr     -- p, inner list expr
  | StageFilterMap Can.Expr Can.Expr  -- f, inner list expr
```

- [ ] **Step 2: Recognize `List.filterMap` in `peelListStage`**

Current (V1):

```haskell
peelListStage :: Can.Expr -> Maybe ListStage
peelListStage expr =
  case collectApplication expr of
    (A.At _ (Can.VarForeign home name _), [f, inner])
      | home == ModuleName.list, name == "map"    -> Just (StageMap f inner)
      | home == ModuleName.list, name == "filter" -> Just (StageFilter f inner)
    _ ->
      Nothing
```

Replace with:

```haskell
peelListStage :: Can.Expr -> Maybe ListStage
peelListStage expr =
  case collectApplication expr of
    (A.At _ (Can.VarForeign home name _), [f, inner])
      | home == ModuleName.list, name == "map"       -> Just (StageMap f inner)
      | home == ModuleName.list, name == "filter"    -> Just (StageFilter f inner)
      | home == ModuleName.list, name == "filterMap" -> Just (StageFilterMap f inner)
    _ ->
      Nothing
```

- [ ] **Step 3: Extend `stageInner`**

Current (V1):

```haskell
stageInner :: ListStage -> Can.Expr
stageInner (StageMap _ inner)    = inner
stageInner (StageFilter _ inner) = inner
```

Replace with:

```haskell
stageInner :: ListStage -> Can.Expr
stageInner (StageMap _ inner)       = inner
stageInner (StageFilter _ inner)    = inner
stageInner (StageFilterMap _ inner) = inner
```

- [ ] **Step 4: Add the synthesized `Maybe` union/pattern helpers**

Insert directly above `wrapStage`'s definition (after `baseStepK`'s definition, before `wrapStage ::
Hints -> Cycle -> StepK -> ListStage -> Names.Tracker StepK`):

```haskell
-- Synthesized Maybe union info + Just/Nothing patterns, used to fuse
-- filterMap's Maybe-producing function via the existing pattern-match
-- compiler (Optimize.Case/Optimize.DecisionTree) instead of hand-rolling a
-- ctor-tag test whose Dev/Prod representation this pass would otherwise
-- have to track itself. The Can.TVar "a" type placeholders are inert:
-- destructCtorArg discards PatternCtorArg's type field with `_`, and
-- DecisionTree.testAtPath discards Can.Union's _u_vars with `_` — nothing
-- past canonicalization reads either, confirmed by reading both call sites.
maybeUnion :: Can.Union
maybeUnion =
  Can.Union ["a"]
    [ Can.Ctor "Just" Index.first 1 [Can.TVar "a"]
    , Can.Ctor "Nothing" Index.second 0 []
    ]
    2
    Can.Normal


pJust :: Name.Name -> Can.Pattern
pJust argName =
  A.At A.zero $ Can.PCtor
    ModuleName.maybe
    Name.maybe
    maybeUnion
    "Just"
    Index.first
    [Can.PatternCtorArg Index.first (Can.TVar "a") (A.At A.zero (Can.PVar argName))]


pNothing :: Can.Pattern
pNothing =
  A.At A.zero $ Can.PCtor
    ModuleName.maybe
    Name.maybe
    maybeUnion
    "Nothing"
    Index.second
    []
```

- [ ] **Step 5: Add the `StageFilterMap` case to `wrapStage`**

Current (V1):

```haskell
wrapStage :: Hints -> Cycle -> StepK -> ListStage -> Names.Tracker StepK
wrapStage hints cycle inner stage =
  case stage of
    StageMap f _ ->
      do  optF <- optimize hints cycle f
          pure $ \elemExpr accExpr -> inner (Opt.Call optF [elemExpr]) accExpr

    StageFilter p _ ->
      do  optP <- optimize hints cycle p
          pure $ \elemExpr accExpr ->
            do  thenBranch <- inner elemExpr accExpr
                pure (Opt.If [(Opt.Call optP [elemExpr], thenBranch)] accExpr)
```

Replace with:

```haskell
wrapStage :: Hints -> Cycle -> StepK -> ListStage -> Names.Tracker StepK
wrapStage hints cycle inner stage =
  case stage of
    StageMap f _ ->
      do  optF <- optimize hints cycle f
          pure $ \elemExpr accExpr -> inner (Opt.Call optF [elemExpr]) accExpr

    StageFilter p _ ->
      do  optP <- optimize hints cycle p
          pure $ \elemExpr accExpr ->
            do  thenBranch <- inner elemExpr accExpr
                pure (Opt.If [(Opt.Call optP [elemExpr], thenBranch)] accExpr)

    StageFilterMap f _ ->
      do  optF <- optimize hints cycle f
          pure $ \elemExpr accExpr ->
            do  temp        <- Names.generate
                yName       <- Names.generate
                justDs      <- destructCase temp (pJust yName)
                thenBranch0 <- inner (Opt.VarLocal yName) accExpr
                let thenBranch = foldr Opt.Destruct thenBranch0 justDs
                pure $ Opt.Let (Opt.Def temp (Opt.Call optF [elemExpr]))
                  (Case.optimize temp temp
                    [ (pJust yName, thenBranch)
                    , (pNothing, accExpr)
                    ])
```

- [ ] **Step 6: Build the compiler and confirm it compiles clean under `-Wall -Werror`**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds (exit code 0), no warnings/errors mentioning `Optimize/Expression.hs`. If
`-Wincomplete-patterns` fires on `stageInner` or `wrapStage`'s `case stage of`, it means Step 3 or
Step 5 was skipped/misapplied — both must handle all three `ListStage` constructors.

- [ ] **Step 7: Commit**

```bash
git add compiler/src/Optimize/Expression.hs
git commit -m "perf: fuse List.filterMap as a producer stage via existing Maybe pattern-match compiler"
```

---

### Task 3: Verify against a real compiler build (structure, correctness, timing)

**Files:**
- None in the repo — this task only creates scratch artifacts outside the repo (per CLAUDE.md: "Use
  a disposable scratch project, not a real one in this repo").

**Interfaces:**
- Consumes: the `elm` binary built in Task 2 (found via `cabal list-bin elm` inside the Docker
  toolchain); the pre-Task-1 commit hash as the "before" reference build (run `git log --oneline -3`
  at execution time and pick the commit before Task 1's first commit, since this plan doesn't know the
  exact hash in advance).
- Produces: nothing consumed by later tasks — terminal verification task for this plan.

**Binary portability note:** the `elm` binary `cabal build` produces is dynamically linked against
the `haskell:9.8.4` image's libraries — do not copy it out and run it directly on the host. Every
invocation of the compiler binary below runs inside a `haskell:9.8.4` container (the binary
bind-mounted read-only). Only the *compiled JS output* (`node ...`) runs directly on the host.

- [ ] **Step 1: Build the "before" reference binary from the pre-Task-1 commit**

```bash
# Task 1 + Task 2 each produced exactly one commit, so the pre-plan
# baseline is HEAD~2 (2 commits before the current HEAD) -- the 3rd line
# of a 3-line `git log`, most-recent-first.
BEFORE_SHA=$(git log --oneline -3 --format=%H | tail -1)
git worktree add /tmp/elm-fusion-v2-before "$BEFORE_SHA"
mkdir -p /tmp/elm-fusion-v2-bin
docker run --rm -v /tmp/elm-fusion-v2-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-fusion-v2-before:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal build elm --ghc-options=-O0 2>&1 | tail -n 40; exit ${PIPESTATUS[0]}'
docker run --rm -v /tmp/elm-fusion-v2-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-fusion-v2-before:/work/dist-newstyle \
  -v /tmp/elm-fusion-v2-bin:/bin-out \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /bin-out/elm-before'
```

Expected: `/tmp/elm-fusion-v2-bin/elm-before` exists. Confirm `$BEFORE_SHA` does **not** contain either
of Task 1/Task 2's commits (`git log --oneline "$BEFORE_SHA" -1` should show a commit predating this
plan's work).

- [ ] **Step 2: Copy the "after" binary (from Task 2) out to the same stable path**

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
docker run --rm -v "$REPO_ROOT":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v /tmp/elm-fusion-v2-bin:/bin-out \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /bin-out/elm-after'
```

Expected: `/tmp/elm-fusion-v2-bin/elm-after` exists. Nothing written inside the repo checkout.

- [ ] **Step 3: Create the scratch project**

```bash
mkdir -p /tmp/elm-fusion-v2-bench/src
cat > /tmp/elm-fusion-v2-bench/elm.json <<'EOF'
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": { "elm/core": "1.0.5", "elm/html": "1.0.0" },
        "indirect": { "elm/json": "1.1.3", "elm/virtual-dom": "1.0.3" }
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
EOF
cat > /tmp/elm-fusion-v2-bench/src/Bench.elm <<'EOF'
module Bench exposing (main)

import Html


isValid : Int -> Bool
isValid x =
    modBy 3 x /= 0


transform : Int -> Int
transform x =
    x * 2 + 1


isBig : Int -> Bool
isBig x =
    modBy 5 x /= 0


maybeTransform : Int -> Maybe Int
maybeTransform x =
    if modBy 3 x /= 0 then
        Just (x * 2)

    else
        Nothing


allNothing : Int -> Maybe Int
allNothing _ =
    Nothing


allJust : Int -> Maybe Int
allJust x =
    Just (x * 2)


sumPipeline : List Int -> Int
sumPipeline xs =
    xs
        |> List.filter isValid
        |> List.map transform
        |> List.filter isBig
        |> List.sum


productPipeline : List Int -> Int
productPipeline xs =
    xs
        |> List.filter isValid
        |> List.product


lengthPipeline : List Int -> Int
lengthPipeline xs =
    xs
        |> List.filter isValid
        |> List.map transform
        |> List.length


fmPipeline : List Int -> Int
fmPipeline xs =
    xs
        |> List.filterMap maybeTransform
        |> List.map transform
        |> List.foldl (+) 0


fmAllNothing : List Int -> Int
fmAllNothing xs =
    xs
        |> List.filterMap allNothing
        |> List.foldl (+) 0


fmAllJust : List Int -> Int
fmAllJust xs =
    xs
        |> List.filterMap allJust
        |> List.foldl (+) 0


mySum : List Int -> Int
mySum =
    List.sum


aliasedPipeline : List Int -> Int
aliasedPipeline xs =
    mySum (List.filter isValid xs)


makeList : Int -> List Int
makeList n =
    List.range 1 n


main : Html.Html msg
main =
    Html.text
        (String.fromInt
            (sumPipeline [ 1 ]
                + productPipeline [ 1 ]
                + lengthPipeline [ 1 ]
                + fmPipeline [ 1 ]
                + fmAllNothing [ 1 ]
                + fmAllJust [ 1 ]
                + aliasedPipeline [ 1 ]
            )
        )
EOF
```

- [ ] **Step 4: Compile with both binaries in `--optimize`, expose internals for direct invocation**

```bash
docker run --rm \
  -v /tmp/elm-fusion-v2-bench:/test \
  -v /tmp/elm-fusion-v2-bin/elm-after:/usr/local/bin/elm:ro \
  -v elm-fusion-v2-home:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --optimize --output=after-prod.js'

docker run --rm \
  -v /tmp/elm-fusion-v2-bench:/test \
  -v /tmp/elm-fusion-v2-bin/elm-before:/usr/local/bin/elm:ro \
  -v elm-fusion-v2-home:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --optimize --output=before-prod.js'

docker run --rm \
  -v /tmp/elm-fusion-v2-bench:/test \
  -v /tmp/elm-fusion-v2-bin/elm-after:/usr/local/bin/elm:ro \
  -v elm-fusion-v2-home:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --output=after-dev.js'

python3 - <<'PYEOF'
expose = """
scope.__sumPipeline = $author$project$Bench$sumPipeline;
scope.__productPipeline = $author$project$Bench$productPipeline;
scope.__lengthPipeline = $author$project$Bench$lengthPipeline;
scope.__fmPipeline = $author$project$Bench$fmPipeline;
scope.__fmAllNothing = $author$project$Bench$fmAllNothing;
scope.__fmAllJust = $author$project$Bench$fmAllJust;
scope.__aliasedPipeline = $author$project$Bench$aliasedPipeline;
scope.__makeList = $author$project$Bench$makeList;
"""
for path in [
    "/tmp/elm-fusion-v2-bench/after-prod.js",
    "/tmp/elm-fusion-v2-bench/after-dev.js",
    "/tmp/elm-fusion-v2-bench/before-prod.js",
]:
    with open(path) as f:
        content = f.read()
    marker = "_Platform_export("
    idx = content.rfind(marker)
    content = content[:idx] + expose + content[idx:]
    with open(path, "w") as f:
        f.write(content)
print("patched after-prod.js, after-dev.js, before-prod.js")
PYEOF
```

Expected: prints the confirmation line, no error (the `$author$project$Bench$...` global names are
stable across Dev/Prod and across the before/after compiler — only record *field* names get
shortened in Prod, not global function names, and this task's fusion changes don't rename anything
either).

- [ ] **Step 5: Structural check — fused pipelines call zero intermediate producers, one terminator**

```bash
python3 - <<'PYEOF'
import re
with open("/tmp/elm-fusion-v2-bench/after-prod.js") as f:
    content = f.read()

def body_of(fn):
    m = re.search(r"\$author\$project\$Bench\$" + fn + r" = function \(xs\) \{(.*?)\n\};", content, re.S)
    assert m, f"could not find {fn}'s body"
    return m.group(1)

sum_body = body_of("sumPipeline")
assert len(re.findall(r"\$elm\$core\$List\$map\b", sum_body)) == 0, "sumPipeline: expected zero List.map calls"
assert len(re.findall(r"\$elm\$core\$List\$filter\b", sum_body)) == 0, "sumPipeline: expected zero List.filter calls"
assert len(re.findall(r"\$elm\$core\$List\$sum\b", sum_body)) == 0, "sumPipeline: expected zero List.sum calls (should be inlined into foldl)"
assert len(re.findall(r"\$elm\$core\$List\$foldl\b", sum_body)) == 1, "sumPipeline: expected exactly one List.foldl call"
print("OK: sumPipeline fused to a single foldl")

product_body = body_of("productPipeline")
assert len(re.findall(r"\$elm\$core\$List\$filter\b", product_body)) == 0, "productPipeline: expected zero List.filter calls"
assert len(re.findall(r"\$elm\$core\$List\$product\b", product_body)) == 0, "productPipeline: expected zero List.product calls"
assert len(re.findall(r"\$elm\$core\$List\$foldl\b", product_body)) == 1, "productPipeline: expected exactly one List.foldl call"
print("OK: productPipeline fused to a single foldl")

length_body = body_of("lengthPipeline")
assert len(re.findall(r"\$elm\$core\$List\$map\b", length_body)) == 0, "lengthPipeline: expected zero List.map calls"
assert len(re.findall(r"\$elm\$core\$List\$length\b", length_body)) == 0, "lengthPipeline: expected zero List.length calls"
assert len(re.findall(r"\$elm\$core\$List\$foldl\b", length_body)) == 1, "lengthPipeline: expected exactly one List.foldl call"
print("OK: lengthPipeline fused to a single foldl")

fm_body = body_of("fmPipeline")
assert len(re.findall(r"\$elm\$core\$List\$filterMap\b", fm_body)) == 0, "fmPipeline: expected zero List.filterMap calls"
assert len(re.findall(r"\$elm\$core\$List\$map\b", fm_body)) == 0, "fmPipeline: expected zero List.map calls"
assert len(re.findall(r"\$elm\$core\$List\$foldl\b", fm_body)) == 1, "fmPipeline: expected exactly one List.foldl call"
assert ".$" in fm_body, "fmPipeline: expected a ctor-tag test ('.$') proving the Maybe match compiled to a real dispatch"
print("OK: fmPipeline fused to a single foldl with a real Maybe ctor-tag test")
PYEOF
```

Expected: four `OK:` lines, no `AssertionError`.

- [ ] **Step 6: Correctness — checksums match "before" across sizes, including edge cases**

```bash
cat > /tmp/elm-fusion-v2-bench/check.js <<'EOF'
const before = require('/tmp/elm-fusion-v2-bench/before-prod.js');
const after = require('/tmp/elm-fusion-v2-bench/after-prod.js');

let failures = 0;
const fns = ['sumPipeline', 'productPipeline', 'lengthPipeline', 'fmPipeline', 'fmAllNothing', 'fmAllJust', 'aliasedPipeline'];
for (const n of [0, 1, 2, 3, 10, 137, 10000]) {
  for (const fn of fns) {
    const bXs = before.__makeList(n);
    const aXs = after.__makeList(n);
    const bResult = before[`__${fn}`](bXs);
    const aResult = after[`__${fn}`](aXs);
    if (bResult !== aResult) {
      console.log(`MISMATCH ${fn} n=${n}: before=${bResult} after=${aResult}`);
      failures++;
    }
  }
}
if (failures === 0) {
  console.log('ALL CHECKSUMS MATCH');
} else {
  console.log(`${failures} MISMATCHES`);
  process.exit(1);
}
EOF
node /tmp/elm-fusion-v2-bench/check.js
```

Expected: prints `ALL CHECKSUMS MATCH`. `fmAllNothing`/`fmAllJust` are the all-`Nothing`/all-`Just`
edge cases; `aliasedPipeline` (via `mySum = List.sum`) is the negative-alias control — expected to run
correctly but **unfused** (not asserted here structurally, only that the *result* is correct, matching
V1's `aliasedPipeline`/`myFoldl` precedent).

- [ ] **Step 7: Dev-mode correctness (exercises Maybe's string ctor tag through the synthesized patterns for the first time)**

```bash
node -e "
const after = require('/tmp/elm-fusion-v2-bench/after-dev.js');
const xs = after.__makeList(137);
console.log('fmPipeline(137) dev =', after.__fmPipeline(xs));
console.log('fmAllNothing(137) dev =', after.__fmAllNothing(xs));
console.log('fmAllJust(137) dev =', after.__fmAllJust(xs));
console.log('sumPipeline(137) dev =', after.__sumPipeline(xs));
"
```

Expected: prints four integers; compare by hand to the Prod checksums from Step 6's `n=137` row for
`fmPipeline`/`fmAllNothing`/`fmAllJust`/`sumPipeline` (must be identical — Dev/Prod differ only in
ctor tag representation, not in this rewrite's arithmetic result).

- [ ] **Step 8: Interleaved timing — confirm the real compiler reproduces the spike's speedup range**

```bash
mkdir -p /tmp/elm-fusion-v2-timing
cat > /tmp/elm-fusion-v2-timing/run-one.js <<'EOF'
const [,, variant, fn, nStr, repsStr] = process.argv;
const m = require(variant === 'before' ? '/tmp/elm-fusion-v2-bench/before-prod.js' : '/tmp/elm-fusion-v2-bench/after-prod.js');
const N = Number(nStr);
const REPS = Number(repsStr);
const xs = m.__makeList(N);
const f = m[`__${fn}`];
let checksum = 0;
for (let i = 0; i < Math.max(3, Math.floor(REPS / 20)); i++) checksum = f(xs);
const start = process.hrtime.bigint();
for (let i = 0; i < REPS; i++) checksum = f(xs);
const end = process.hrtime.bigint();
console.log(JSON.stringify({ variant, fn, N, REPS, ms: Number(end - start) / 1e6, checksum }));
EOF

for fn in sumPipeline productPipeline lengthPipeline fmPipeline; do
  echo "=== $fn ==="
  node /tmp/elm-fusion-v2-timing/run-one.js before $fn 200000 100
  node /tmp/elm-fusion-v2-timing/run-one.js after $fn 200000 100
  node /tmp/elm-fusion-v2-timing/run-one.js before $fn 200000 100
  node /tmp/elm-fusion-v2-timing/run-one.js after $fn 200000 100
done
```

Expected: for each function, `after`'s `ms` substantially lower than `before`'s, `checksum` identical
within each function, landing in the same ballpark the spike found (`sum`/`product`/`length`-style
pipelines: 6x-40x depending on stage count; `filterMap`-style: 3.6x-7x) — real numbers will differ
somewhat from the hand-patch spike since the real compiler's synthesized step/Maybe-dispatch isn't
textually identical, but the qualitative gap must hold.

- [ ] **Step 9: Clean up scratch artifacts**

```bash
git worktree remove /tmp/elm-fusion-v2-before --force
docker volume rm elm-dist-fusion-v2-before
docker volume rm elm-fusion-v2-home
rm -rf /tmp/elm-fusion-v2-bench /tmp/elm-fusion-v2-bin /tmp/elm-fusion-v2-timing
```

No commit for this task — it's verification only, produces no repo changes.
