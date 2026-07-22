# Cross-Container Conversion Fusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fuse `List.foldl step acc chain`-shaped expressions, where `chain` (after peeling any
number — including zero — of `List.map`/`List.filter`/`List.filterMap` stages) bottoms out at
`Dict.toList e`, `Dict.keys e`, `Dict.values e`, `Set.toList e`, or `Array.toList e`, into a single
direct `Dict.foldl`/`Set.foldl`/`Array.foldl` call over `e` with an adapted composed step —
eliminating the conversion's own intermediate list allocation and traversal pass. The
cross-container analogue of the already-shipped [[list-foldl-fusion-plan]],
[[array-chain-fusion-spike]], [[dict-map-filter-fusion-spike]], and
[[set-filter-foldl-fusion-plan]].

**Architecture:** A pure syntactic rewrite added to `Optimize.Expression.hs`'s `optimize` function —
one new guarded alternative inserted immediately before the existing `List.foldl` fusion guard
(so it takes priority when applicable), recognizing the five conversions as a new kind of
`peelChain` base via a new `peelCrossBase`, and reusing the **existing**
`ListStage`/`StepK`/`wrapStage`/`baseStepK`/`peelChain` machinery unchanged — a `List.map`/`filter`
chain between the conversion and the `foldl` keeps fusing exactly as it does today. Only the final
terminator and its key/value adapter are new (`buildFusedCrossFold`). No new `AST.Optimized`
constructor, no `.elmo` format change, no `Generate.*` changes, no `elm/core` changes.

**Tech Stack:** Haskell (GHC 9.8.4 via the project's Docker toolchain).

## Global Constraints

- Build with `-Wall -Werror` (baked into `elm.cabal`) — any unused import/bind fails the build.
- No `.elmo`/`.elmi` binary format change — must not touch `AST.Optimized`'s `Data.Binary` instances.
- This rewrite is **not** `Mode`-gated (runs identically in Dev and Prod), matching every fusion
  pass before it.
- Full design rationale, semantics proof, and scope boundaries:
  `docs/superpowers/specs/2026-07-22-cross-container-conversion-fusion-design.md`.
- Scope is deliberately narrow: only the `List.foldl` terminator, only these five conversions
  (`Dict.toList`/`keys`/`values`, `Set.toList`, `Array.toList`). Do **not** add in this plan:
  `Dict.fromList`/`Set.fromList`/`Array.fromList` (the reverse direction — these build a real
  tree/trie, not a mere projection, a fundamentally different and unvalidated mechanism);
  `List.sum`/`List.product`/`List.length` reaching through one of these conversions; `List.foldr`
  reaching through one (no existing `List.foldr` fusion guard to extend — see
  [[list-foldr-fusion-spike]]); or bare conversion chains with no `foldl` terminator (a future
  extension of [[bare-producer-chain-fusion-spike]], not this plan).
- The new guard clause must be inserted **before** (not after, not merged into) the existing
  `stages@(_:_)`-gated `List.foldl` guard, so that an ordinary `list |> List.map f |> List.foldl g
  z` (a real list, not one of the five conversions) still falls through to, and is handled
  identically by, the untouched existing guard.
- Fusion only fires on **direct syntactic** calls to the five conversions and to `List.foldl` (any
  import style — qualified, aliased, or exposed — all canonicalize to the same identity, via
  `collectApplication`). It does **not** fire through a local alias (e.g. `toPairs = Dict.toList`);
  that call site is simply left unoptimized, never miscompiled.

---

### Task 1: Implement the fusion rewrite in `Optimize.Expression.hs`

**Files:**
- Modify: `compiler/src/Optimize/Expression.hs`

**Interfaces:**
- Consumes: `Can.Expr`/`Can.Expr_` and `Opt.Expr` (already imported qualified as `Can`/`Opt`),
  `Names.Tracker`/`Names.generate`/`Names.registerGlobal` (`Optimize.Names`, imported qualified as
  `Names`), `ModuleName.dict`/`ModuleName.set`/`ModuleName.array` (`Elm.ModuleName`, imported
  qualified as `ModuleName`, already used throughout this file), `foldM` (`Control.Monad`, already
  imported unqualified), `collectApplication`, `ListStage`, `peelChain`, `StepK`, `wrapStage`,
  `baseStepK` (all already defined earlier in this same file, in the LIST PIPELINE FUSION section —
  none of them are List-specific, exactly as the ARRAY PIPELINE FUSION section's own comment
  already notes when it reuses the same four).
- Produces: nothing consumed by later tasks in this plan — Task 2 only builds and runs the
  resulting compiler binary, it doesn't call any Haskell function from Task 1 directly.

- [ ] **Step 1: Add `CrossBase`, `peelCrossBase`, `buildFusedCrossFold`**

Find this existing code in `compiler/src/Optimize/Expression.hs` (the end of the SET PIPELINE
FUSION section, immediately before the `-- BARE PRODUCER-CHAIN FUSION` comment):

```haskell
buildFusedSetFold :: Hints -> Cycle -> SetStepK -> Opt.Expr -> [SetStage] -> Can.Expr -> Names.Tracker Opt.Expr
buildFusedSetFold hints cycle base initExpr stages source =
  do  optSource <- optimize hints cycle source
      composed  <- foldM (wrapSetStage hints cycle) base stages
      elemName  <- Names.generate
      accName   <- Names.generate
      body      <- composed (Opt.VarLocal elemName) (Opt.VarLocal accName)
      optFoldl  <- Names.registerGlobal ModuleName.set "foldl"
      pure $ Opt.Call optFoldl
        [ Opt.Function [elemName, accName] body
        , initExpr
        , optSource
        ]


-- BARE PRODUCER-CHAIN FUSION (map/filter/filterMap, no terminator)
```

Insert a new section between `buildFusedSetFold`'s closing bracket and the
`-- BARE PRODUCER-CHAIN FUSION` comment:

```haskell
buildFusedSetFold :: Hints -> Cycle -> SetStepK -> Opt.Expr -> [SetStage] -> Can.Expr -> Names.Tracker Opt.Expr
buildFusedSetFold hints cycle base initExpr stages source =
  do  optSource <- optimize hints cycle source
      composed  <- foldM (wrapSetStage hints cycle) base stages
      elemName  <- Names.generate
      accName   <- Names.generate
      body      <- composed (Opt.VarLocal elemName) (Opt.VarLocal accName)
      optFoldl  <- Names.registerGlobal ModuleName.set "foldl"
      pure $ Opt.Call optFoldl
        [ Opt.Function [elemName, accName] body
        , initExpr
        , optSource
        ]


-- CROSS-CONTAINER CONVERSION FUSION (Dict.toList/keys/values, Set.toList,
-- Array.toList feeding a List.foldl chain)
--
-- See docs/superpowers/specs/2026-07-22-cross-container-conversion-fusion-design.md
-- for the full derivation. Reuses ListStage/StepK/wrapStage/baseStepK/
-- peelChain verbatim -- a List.map/filter/filterMap chain sitting between
-- one of these five conversions and the terminating List.foldl keeps
-- working exactly as it does today, unchanged. The only new pieces are
-- recognizing the conversion itself as a peelChain base, and picking a
-- different terminator (Dict.foldl/Set.foldl/Array.foldl) with the right
-- key/value adapter once one is found.


-- One of the five recognized producer-side conversions, carrying the
-- converted-from container expression (not yet optimized).
data CrossBase
  = CBDictToList Can.Expr    -- Dict.toList e:  elemExpr = (k, v) tuple, terminator = Dict.foldl
  | CBDictKeys Can.Expr      -- Dict.keys e:    elemExpr = k,            terminator = Dict.foldl
  | CBDictValues Can.Expr    -- Dict.values e:  elemExpr = v,            terminator = Dict.foldl
  | CBSetToList Can.Expr     -- Set.toList e:   elemExpr = k,            terminator = Set.foldl
  | CBArrayToList Can.Expr   -- Array.toList e: elemExpr = v,            terminator = Array.foldl


-- Nothing => not one of the five recognized conversions => this pass
-- doesn't apply here; the existing (unmodified) stages@(_:_)-gated
-- List.foldl guard below still fires if `stages` is non-empty, or the
-- expression is left for ordinary optimize recursion if not. Only
-- elm/core's own Dict.toList/keys/values and Set.toList/Array.toList
-- match (via either Can.Call or |>/<| syntax, thanks to
-- collectApplication); a local alias falls through untouched.
peelCrossBase :: Can.Expr -> Maybe CrossBase
peelCrossBase expr =
  case collectApplication expr of
    (A.At _ (Can.VarForeign home name _), [e])
      | home == ModuleName.dict,  name == "toList" -> Just (CBDictToList e)
      | home == ModuleName.dict,  name == "keys"   -> Just (CBDictKeys e)
      | home == ModuleName.dict,  name == "values" -> Just (CBDictValues e)
      | home == ModuleName.set,   name == "toList" -> Just (CBSetToList e)
      | home == ModuleName.array, name == "toList" -> Just (CBArrayToList e)
    _ ->
      Nothing


-- Builds the fused replacement for `List.foldl step acc chain`, where
-- `chain`'s peelChain base matched one of the five CrossBase shapes.
-- `stages` may be empty (a bare `List.foldl f z (Dict.toList d)`, no
-- map/filter in between) -- unlike buildFusedFold's callers, the dispatch
-- clause below deliberately does not gate this on `stages@(_:_)`, since
-- even zero stages is worth fusing here: the win is skipping the
-- conversion's own list build, not the map/filter stages, which cost
-- exactly the same fused or not.
buildFusedCrossFold :: Hints -> Cycle -> StepK -> Opt.Expr -> [ListStage] -> CrossBase -> Names.Tracker Opt.Expr
buildFusedCrossFold hints cycle base initExpr stages crossBase =
  do  composed <- foldM (wrapStage hints cycle) base stages
      case crossBase of
        CBDictToList e  -> dictTerminator composed e (\k v -> Opt.Tuple k v Nothing)
        CBDictKeys e    -> dictTerminator composed e (\k _ -> k)
        CBDictValues e  -> dictTerminator composed e (\_ v -> v)
        CBSetToList e   -> singleArgTerminator ModuleName.set    composed e
        CBArrayToList e -> singleArgTerminator ModuleName.array composed e
  where
    dictTerminator composed e project =
      do  optE     <- optimize hints cycle e
          keyName  <- Names.generate
          valName  <- Names.generate
          accName  <- Names.generate
          body     <- composed (project (Opt.VarLocal keyName) (Opt.VarLocal valName)) (Opt.VarLocal accName)
          optFoldl <- Names.registerGlobal ModuleName.dict "foldl"
          pure $ Opt.Call optFoldl
            [ Opt.Function [keyName, valName, accName] body
            , initExpr
            , optE
            ]

    singleArgTerminator home composed e =
      do  optE     <- optimize hints cycle e
          elemName <- Names.generate
          accName  <- Names.generate
          body     <- composed (Opt.VarLocal elemName) (Opt.VarLocal accName)
          optFoldl <- Names.registerGlobal home "foldl"
          pure $ Opt.Call optFoldl
            [ Opt.Function [elemName, accName] body
            , initExpr
            , optE
            ]


-- BARE PRODUCER-CHAIN FUSION (map/filter/filterMap, no terminator)
```

(Only the new block in the middle — from `-- CROSS-CONTAINER CONVERSION FUSION` through
`singleArgTerminator`'s closing bracket — is new; the surrounding `buildFusedSetFold` and
`-- BARE PRODUCER-CHAIN FUSION` lines are shown for anchoring and must be left unchanged.)

- [ ] **Step 2: Wire the new dispatch guard**

Find this existing guard in the same file (the very first guard of the fusion cluster, at the top
of `optimize`'s big `_ | ... -> ...` alternative):

```haskell
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
```

Insert a new guard alternative immediately **before** it (so it is tried first — Haskell tries
guards top-to-bottom, first match wins):

```haskell
      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "foldl"
      , [stepArg, accArg, listArg] <- args
      , (stages, source) <- peelChain listArg
      , Just crossBase <- peelCrossBase source
      ->
          do  optStep <- optimize hints cycle stepArg
              optAcc  <- optimize hints cycle accArg
              buildFusedCrossFold hints cycle (baseStepK optStep) optAcc stages crossBase

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
```

(Only the new block in the middle is new; both surrounding guards are shown for anchoring and must
be left otherwise unchanged.)

- [ ] **Step 3: Build the compiler and confirm it compiles clean under `-Wall -Werror`**

Run (from the repo root):

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
git commit -m "perf: fuse Dict.toList/keys/values, Set.toList, Array.toList into List.foldl's terminator"
```

---

### Task 2: Verify against a real compiler build (structure, correctness, order-sensitivity, timing)

**Files:**
- None in the repo — this task only creates scratch artifacts outside the repo (per CLAUDE.md: "Use
  a disposable scratch project, not a real one in this repo").

**Interfaces:**
- Consumes: the `elm` binary built in Task 1 (found via `cabal list-bin elm` inside the Docker
  toolchain); the pre-Task-1 commit hash as the "before" reference build (run `git log --oneline -2
  --format=%H | tail -1` at execution time to get the exact hash, since this plan doesn't know it in
  advance).
- Produces: nothing consumed by later tasks — this is the terminal verification task for this plan.

**Binary portability note:** the `elm` binary `cabal build` produces is dynamically linked against
the `haskell:9.8.4` image's libraries — do not copy it out and run it directly on the host. Every
invocation of the compiler binary below runs inside a `haskell:9.8.4` container (the binary
bind-mounted read-only). Only the *compiled JS output* (`node ...`) runs directly on the host.

- [ ] **Step 1: Build the "before" reference binary from the pre-Task-1 commit**

```bash
BEFORE_SHA=$(git log --oneline -2 --format=%H | tail -1)
git worktree add /tmp/elm-crosscontainer-before "$BEFORE_SHA"
mkdir -p /tmp/elm-crosscontainer-bin
docker run --rm -v /tmp/elm-crosscontainer-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-crosscontainer-before:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal build elm --ghc-options=-O0 2>&1 | tail -n 40; exit ${PIPESTATUS[0]}'
docker run --rm -v /tmp/elm-crosscontainer-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-crosscontainer-before:/work/dist-newstyle \
  -v /tmp/elm-crosscontainer-bin:/bin-out \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /bin-out/elm-before'
```

Expected: `/tmp/elm-crosscontainer-bin/elm-before` exists.

- [ ] **Step 2: Copy the "after" binary (from Task 1) out to the same stable path**

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
docker run --rm -v "$REPO_ROOT":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v /tmp/elm-crosscontainer-bin:/bin-out \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /bin-out/elm-after'
```

Expected: `/tmp/elm-crosscontainer-bin/elm-after` exists. Nothing written inside the repo checkout.

- [ ] **Step 3: Create the scratch project**

Note: every fused function below folds via `(\x acc -> x :: acc)` (or `(\pair acc -> pair :: acc)`
for the pair case) into a real `List` — a non-commutative, order-sensitive result (unlike a plain
sum, which the original spike showed can silently mask a traversal-order bug — see the design
spec's Motivation section). `plainListMapFilterFoldl` is a regression check: it does **not** go
through any of the five conversions, so it must still be fused by the pre-existing,
untouched `stages@(_:_)`-gated guard exactly as before this change.

**Critical: use two separate project directories, one per compiler binary — never compile
"before" and "after" into the same directory.** `elm make` writes a project-local build cache to
`<project>/elm-stuff/`, keyed only on the *source file's* content, not on which compiler binary
produced it. Compiling "before" and "after" into the same directory in sequence lets the second
`elm make` call silently reuse the first binary's already-compiled output — with no error, no
warning, and no exit-code signal — collapsing the whole comparison into measuring one binary
against itself (see `docs/superpowers/specs/2026-07-21-spike-runbook.md`, Section 7, and memory
`elm-stuff-cache-contamination-finding.md`). `after-prod.js` and `after-dev.js` may safely share
one directory (same binary compiling twice); `before-prod.js` must use a separate one.

```bash
mkdir -p /tmp/elm-crosscontainer-bench-after/src /tmp/elm-crosscontainer-bench-before/src
cat > /tmp/elm-crosscontainer-bench-after/elm.json <<'EOF'
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": { "elm/core": "1.0.5", "elm/json": "1.1.3" },
        "indirect": {}
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
EOF
cp /tmp/elm-crosscontainer-bench-after/elm.json /tmp/elm-crosscontainer-bench-before/elm.json
cat > /tmp/elm-crosscontainer-bench-after/src/Bench.elm <<'EOF'
module Bench exposing (main)

import Array exposing (Array)
import Dict exposing (Dict)
import Platform
import Set exposing (Set)


dictToListFoldl : Dict Int Int -> List ( Int, Int )
dictToListFoldl d =
    List.foldl (\pair acc -> pair :: acc) [] (Dict.toList d)


dictKeysFoldl : Dict Int Int -> List Int
dictKeysFoldl d =
    List.foldl (\k acc -> k :: acc) [] (Dict.keys d)


dictValuesFoldl : Dict Int Int -> List Int
dictValuesFoldl d =
    List.foldl (\v acc -> v :: acc) [] (Dict.values d)


setToListFoldl : Set Int -> List Int
setToListFoldl s =
    List.foldl (\k acc -> k :: acc) [] (Set.toList s)


arrayToListFoldl : Array Int -> List Int
arrayToListFoldl arr =
    List.foldl (\v acc -> v :: acc) [] (Array.toList arr)


chainedDictToListFoldl : Dict Int Int -> List Int
chainedDictToListFoldl d =
    Dict.toList d
        |> List.map (\( k, v ) -> k + v)
        |> List.filter (\x -> modBy 3 x /= 0)
        |> List.foldl (\x acc -> x :: acc) []


plainListMapFilterFoldl : List Int -> Int
plainListMapFilterFoldl xs =
    xs
        |> List.map (\x -> x * 2)
        |> List.filter (\x -> modBy 3 x /= 0)
        |> List.foldl (+) 0


buildDict : Int -> Dict Int Int
buildDict n =
    List.foldl (\i d -> Dict.insert i (i * 2) d) Dict.empty (List.range 0 (n - 1))


buildArray : Int -> Array Int
buildArray n =
    Array.fromList (List.range 0 (n - 1))


buildSet : Int -> Set Int
buildSet n =
    List.foldl Set.insert Set.empty (List.range 0 (n - 1))


buildListOfInts : Int -> List Int
buildListOfInts n =
    List.range 0 (n - 1)


type alias Model =
    { dictToListFoldl : Dict Int Int -> List ( Int, Int )
    , dictKeysFoldl : Dict Int Int -> List Int
    , dictValuesFoldl : Dict Int Int -> List Int
    , setToListFoldl : Set Int -> List Int
    , arrayToListFoldl : Array Int -> List Int
    , chainedDictToListFoldl : Dict Int Int -> List Int
    , plainListMapFilterFoldl : List Int -> Int
    , buildDict : Int -> Dict Int Int
    , buildArray : Int -> Array Int
    , buildSet : Int -> Set Int
    , buildListOfInts : Int -> List Int
    }


main : Program () Model ()
main =
    Platform.worker
        { init =
            \_ ->
                ( { dictToListFoldl = dictToListFoldl
                  , dictKeysFoldl = dictKeysFoldl
                  , dictValuesFoldl = dictValuesFoldl
                  , setToListFoldl = setToListFoldl
                  , arrayToListFoldl = arrayToListFoldl
                  , chainedDictToListFoldl = chainedDictToListFoldl
                  , plainListMapFilterFoldl = plainListMapFilterFoldl
                  , buildDict = buildDict
                  , buildArray = buildArray
                  , buildSet = buildSet
                  , buildListOfInts = buildListOfInts
                  }
                , Cmd.none
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
EOF
cp /tmp/elm-crosscontainer-bench-after/src/Bench.elm /tmp/elm-crosscontainer-bench-before/src/Bench.elm
```

Note: `main`'s `Model` holds every benchmarked function so Prod-mode dead-code elimination (a
reachability graph over top-level definitions, not a call-tracer) keeps them all present in the
compiled output even though `init` never actually calls them — the same trick every earlier fusion
plan's own verification task used.

- [ ] **Step 4: Compile with both binaries in `--optimize`, expose internals for direct invocation**

`after-prod.js` and `after-dev.js` both compile with `elm-after` into `bench-after` (same binary,
same directory — safe). `before-prod.js` compiles with `elm-before` into the separate
`bench-before` directory (different binary — must not share a directory with any `elm-after`
compile; see Step 3's note).

```bash
docker run --rm \
  -v /tmp/elm-crosscontainer-bench-after:/test \
  -v /tmp/elm-crosscontainer-bin/elm-after:/usr/local/bin/elm:ro \
  -v elm-crosscontainer-home-after:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --optimize --output=after-prod.js'

docker run --rm \
  -v /tmp/elm-crosscontainer-bench-before:/test \
  -v /tmp/elm-crosscontainer-bin/elm-before:/usr/local/bin/elm:ro \
  -v elm-crosscontainer-home-before:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --optimize --output=before-prod.js'

docker run --rm \
  -v /tmp/elm-crosscontainer-bench-after:/test \
  -v /tmp/elm-crosscontainer-bin/elm-after:/usr/local/bin/elm:ro \
  -v elm-crosscontainer-home-after:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --output=after-dev.js'

python3 - <<'PYEOF'
for path in ["/tmp/elm-crosscontainer-bench-after/after-prod.js",
             "/tmp/elm-crosscontainer-bench-before/before-prod.js",
             "/tmp/elm-crosscontainer-bench-after/after-dev.js"]:
    with open(path) as f:
        content = f.read()
    marker = "_Platform_export("
    idx = content.rfind(marker)
    expose = """
scope.__dictToListFoldl = $author$project$Bench$dictToListFoldl;
scope.__dictKeysFoldl = $author$project$Bench$dictKeysFoldl;
scope.__dictValuesFoldl = $author$project$Bench$dictValuesFoldl;
scope.__setToListFoldl = $author$project$Bench$setToListFoldl;
scope.__arrayToListFoldl = $author$project$Bench$arrayToListFoldl;
scope.__chainedDictToListFoldl = $author$project$Bench$chainedDictToListFoldl;
scope.__plainListMapFilterFoldl = $author$project$Bench$plainListMapFilterFoldl;
scope.__buildDict = $author$project$Bench$buildDict;
scope.__buildArray = $author$project$Bench$buildArray;
scope.__buildSet = $author$project$Bench$buildSet;
scope.__buildListOfInts = $author$project$Bench$buildListOfInts;
"""
    content = content[:idx] + expose + content[idx:]
    with open(path, "w") as f:
        f.write(content)
    print(f"patched {path}")
PYEOF
```

Expected: all three files patched without error (the `$author$project$Bench$...` names are stable
across Dev/Prod — only record *field* names get shortened in Prod, not global function names).

- [ ] **Step 5: Structural check — each fused function shows zero conversion calls and exactly one direct terminator call; the plain-list regression check still shows zero `List.map`/`List.filter` calls**

```bash
python3 - <<'PYEOF'
import re

with open("/tmp/elm-crosscontainer-bench-after/after-prod.js") as f:
    content = f.read()

def body_of(fn_name):
    m = re.search(r"\$author\$project\$Bench\$" + fn_name + r" = function \([^)]*\) \{(.*?)\n\};", content, re.S)
    assert m, f"could not find {fn_name} in after-prod.js"
    return m.group(1)

def count(pattern, body):
    return len(re.findall(pattern, body))

checks = [
    ("dictToListFoldl", ["\\$elm\\$core\\$Dict\\$toList\\b", "\\$elm\\$core\\$List\\$foldl\\b"], "\\$elm\\$core\\$Dict\\$foldl\\b"),
    ("dictKeysFoldl", ["\\$elm\\$core\\$Dict\\$keys\\b", "\\$elm\\$core\\$List\\$foldl\\b"], "\\$elm\\$core\\$Dict\\$foldl\\b"),
    ("dictValuesFoldl", ["\\$elm\\$core\\$Dict\\$values\\b", "\\$elm\\$core\\$List\\$foldl\\b"], "\\$elm\\$core\\$Dict\\$foldl\\b"),
    ("setToListFoldl", ["\\$elm\\$core\\$Set\\$toList\\b", "\\$elm\\$core\\$List\\$foldl\\b"], "\\$elm\\$core\\$Set\\$foldl\\b"),
    ("arrayToListFoldl", ["\\$elm\\$core\\$Array\\$toList\\b", "\\$elm\\$core\\$List\\$foldl\\b"], "\\$elm\\$core\\$Array\\$foldl\\b"),
    ("chainedDictToListFoldl", ["\\$elm\\$core\\$Dict\\$toList\\b", "\\$elm\\$core\\$List\\$foldl\\b", "\\$elm\\$core\\$List\\$map\\b", "\\$elm\\$core\\$List\\$filter\\b"], "\\$elm\\$core\\$Dict\\$foldl\\b"),
]

for fn_name, forbidden_patterns, required_pattern in checks:
    body = body_of(fn_name)
    for pat in forbidden_patterns:
        n = count(pat, body)
        assert n == 0, f"{fn_name}: expected zero matches for {pat}, found {n}"
    n = count(required_pattern, body)
    assert n == 1, f"{fn_name}: expected exactly one match for {required_pattern}, found {n}"
    print(f"OK: {fn_name} fused (zero conversion/List.foldl calls, one direct terminator call)")

# Regression check: a plain list (not one of the five conversions) must still go
# through the pre-existing, untouched map/filter-into-foldl fusion.
body = body_of("plainListMapFilterFoldl")
assert count("\\$elm\\$core\\$List\\$map\\b", body) == 0, "plainListMapFilterFoldl: expected zero List.map calls (pre-existing fusion regressed)"
assert count("\\$elm\\$core\\$List\\$filter\\b", body) == 0, "plainListMapFilterFoldl: expected zero List.filter calls (pre-existing fusion regressed)"
assert count("\\$elm\\$core\\$List\\$foldl\\b", body) == 1, "plainListMapFilterFoldl: expected exactly one List.foldl call"
print("OK: plainListMapFilterFoldl still fused by the pre-existing, unmodified guard (no regression)")
PYEOF
```

Expected: seven `OK:` lines, no `AssertionError`. (Each regex's `\b` after the function name also
matches the `$unwrapped`-suffixed variant `Generate.Mode`'s existing arity analysis may redirect
calls to — see memory `unwrapped-hofs-plan.md` — so these checks catch either form.)

- [ ] **Step 6: Correctness — structural equality vs. "before" across sizes, including edge cases**

```bash
cat > /tmp/elm-crosscontainer-bench-after/check.js <<'EOF'
const before = require('/tmp/elm-crosscontainer-bench-before/before-prod.js');
const after = require('/tmp/elm-crosscontainer-bench-after/after-prod.js');

let failures = 0;
for (const n of [0, 1, 2, 3, 10, 137, 10000]) {
  const bDict = before.__buildDict(n);
  const aDict = after.__buildDict(n);
  const bArr = before.__buildArray(n);
  const aArr = after.__buildArray(n);
  const bSet = before.__buildSet(n);
  const aSet = after.__buildSet(n);
  const bList = before.__buildListOfInts(n);
  const aList = after.__buildListOfInts(n);

  const cases = [
    ['dictToListFoldl', bDict, aDict],
    ['dictKeysFoldl', bDict, aDict],
    ['dictValuesFoldl', bDict, aDict],
    ['setToListFoldl', bSet, aSet],
    ['arrayToListFoldl', bArr, aArr],
    ['chainedDictToListFoldl', bDict, aDict],
    ['plainListMapFilterFoldl', bList, aList],
  ];
  for (const [fn, bArg, aArg] of cases) {
    const bResult = JSON.stringify(before[`__${fn}`](bArg));
    const aResult = JSON.stringify(after[`__${fn}`](aArg));
    if (bResult !== aResult) {
      console.log(`MISMATCH ${fn} n=${n}: before=${bResult} after=${aResult}`);
      failures++;
    }
  }
}
if (failures === 0) {
  console.log('ALL RESULTS MATCH (structural, order-sensitive)');
} else {
  console.log(`${failures} MISMATCHES`);
  process.exit(1);
}
EOF
node /tmp/elm-crosscontainer-bench-after/check.js
```

Expected: prints `ALL RESULTS MATCH (structural, order-sensitive)`. (`JSON.stringify` on a
cons-list-of-ints/tuples value is safe here since both sides use the identical, untouched
List/Tuple representation — this plan never changes List or Tuple codegen.)

- [ ] **Step 7: Dev-mode correctness (this rewrite is unconditional on Mode)**

```bash
node -e "
const after = require('/tmp/elm-crosscontainer-bench-after/after-dev.js');
const dict = after.__buildDict(137);
console.log('dictToListFoldl(137) dev =', JSON.stringify(after.__dictToListFoldl(dict)));
console.log('chainedDictToListFoldl(137) dev =', JSON.stringify(after.__chainedDictToListFoldl(dict)));
"
```

Expected: prints two JSON arrays; compare by hand to the Prod results from Step 6's `n=137` row for
`dictToListFoldl`/`chainedDictToListFoldl` (must be identical — Dev/Prod differ only in ctor tag
representation, not in this rewrite's element order or values).

- [ ] **Step 8: Interleaved timing — confirm the real compiler reproduces the spike's speedup range**

```bash
mkdir -p /tmp/elm-crosscontainer-timing
cat > /tmp/elm-crosscontainer-timing/run-one.js <<'EOF'
const [,, variant, fn, nStr, repsStr] = process.argv;
const m = require(variant === 'before' ? '/tmp/elm-crosscontainer-bench-before/before-prod.js' : '/tmp/elm-crosscontainer-bench-after/after-prod.js');
const N = Number(nStr);
const REPS = Number(repsStr);
const buildFor = { dictToListFoldl: '__buildDict', dictKeysFoldl: '__buildDict', dictValuesFoldl: '__buildDict', setToListFoldl: '__buildSet', arrayToListFoldl: '__buildArray', chainedDictToListFoldl: '__buildDict' };
const structure = m[buildFor[fn]](N);
const target = m[`__${fn}`];
let result;
for (let i = 0; i < Math.max(3, Math.floor(REPS / 20)); i++) result = target(structure);
const start = process.hrtime.bigint();
for (let i = 0; i < REPS; i++) result = target(structure);
const end = process.hrtime.bigint();
let len = 0;
for (let n = result; n && n.$ === 1; n = n.b) len++;
console.log(JSON.stringify({ variant, fn, N, REPS, ms: Number(end - start) / 1e6, resultLen: len }));
EOF

for fn in dictToListFoldl dictKeysFoldl dictValuesFoldl setToListFoldl arrayToListFoldl chainedDictToListFoldl; do
  echo "=== $fn ==="
  node /tmp/elm-crosscontainer-timing/run-one.js before $fn 100000 200
  node /tmp/elm-crosscontainer-timing/run-one.js after $fn 100000 200
  node /tmp/elm-crosscontainer-timing/run-one.js before $fn 100000 200
  node /tmp/elm-crosscontainer-timing/run-one.js after $fn 100000 200
done
```

Expected: for each function, `after`'s `ms` is lower than `before`'s (spike found 1.16x-3.4x,
growing with `n` — at `n=100000` expect roughly the 1.3x-2.0x band from the spike's table),
`resultLen` identical within each function, and `after` beating `before` for every function tested.

**If this instead shows `after` at parity with or slower than `before`:** before concluding the
optimization has no real effect, re-run Step 5's structural check against `before-prod.js`
specifically (not just `after-prod.js`). If `before`'s functions already show the fused shape
(zero conversion calls, one direct terminator call), the two binaries were never actually compared
— see `docs/superpowers/specs/2026-07-21-spike-runbook.md` Section 7 for this exact failure mode
and its fix (separate project directories, already applied in Steps 3-4 above as written).

- [ ] **Step 9: Clean up scratch artifacts**

```bash
git worktree remove /tmp/elm-crosscontainer-before --force
docker volume rm elm-dist-crosscontainer-before
docker volume rm elm-crosscontainer-home-before
docker volume rm elm-crosscontainer-home-after
rm -rf /tmp/elm-crosscontainer-bench-before /tmp/elm-crosscontainer-bench-after /tmp/elm-crosscontainer-bin /tmp/elm-crosscontainer-timing
```

No commit for this task — it's verification only, produces no repo changes.

---

### Task 3: Fix per-element `F2`/`A2` overhead in the synthesized step call (regression found in Task 2)

**Why this task exists:** Task 2's timing check found that 4 of 6 benchmarked functions
(`dictKeysFoldl`, `dictValuesFoldl`, `setToListFoldl`, `arrayToListFoldl` — all zero-`stages`
cases) were **~1.3-1.4x slower** after fusion, not faster. Root cause (confirmed by reading the
generated JS and the relevant `Generate/JavaScript/Expression.hs`/`Generate/Mode.hs` code paths):
`buildFusedCrossFold`'s synthesized per-element callback calls the user's own step function
(`optStep`) via a **nested** `Opt.Call optStep [...]` sitting inside the callback's body. When
`optStep` is itself a literal `Opt.Function` (the common case — the user wrote an inline lambda),
`Generate.JavaScript.Expression`'s call-site dispatch (`generateCall`, which only recognizes
`Opt.VarGlobal`/`Opt.VarLocal` calees with a *known* arity — see `Generate/Mode.hs`'s
`computeArities` and `Generate/JavaScript/Expression.hs`'s `extendWithLocalArity`/
`generateDirectLocalCall`) does not recognize this shape at all, so it falls through to the
generic `A2` dispatch, which wraps the literal `Opt.Function` in a fresh `F2(...)` **every time the
outer callback runs** — i.e. once per Dict/Set/Array/List element, inside the hot loop. This is
strictly worse than the *unfused* baseline, where the same lambda sits as the literal argument to
`List.foldl` and *does* get the free, already-shipped `$unwrapped`/no-wrap treatment
(`generateRawCallback`).

**Fix:** hoist `optStep` into a single `Opt.Let`-bound local, outside the per-element callback,
and have the callback call that local instead of `optStep` directly. This reuses the *already
existing, already-shipped* `extendWithLocalArity`/`Mode.addLocalArity`/`generateDirectLocalCall`
machinery (`Generate/JavaScript/Expression.hs:1091-1097` and `:542-546`) unchanged — when `optStep`
is a literal `Opt.Function`, the hoisted local's arity gets recorded and calls to it compile to a
direct `.f(...)` call (no `A2` at all); when it isn't (e.g. a named top-level function reference),
the hoist still eliminates the per-element re-wrapping since whatever `optStep` evaluates to is
now computed once, not once per element. **Scoped entirely to `buildFusedCrossFold` and its call
site** — `baseStepK`/`wrapStage`/`StepK` (shared with the already-shipped `buildFusedFold`/
`buildFusedArrayFold`) are **not** modified, since those fusions never trigger with zero stages (a
`stages@(_:_)` gate on every one of their guards) and are not implicated by this regression;
touching them would risk regressing already-verified, shipped behavior for no benefit this plan
needs.

**Files:**
- Modify: `compiler/src/Optimize/Expression.hs`

**Interfaces:**
- Consumes: `Opt.Let`, `Opt.Def` (`AST.Optimized`, already imported qualified as `Opt` — `Def` is
  `Opt.Def Name.Name Opt.Expr`, `Opt.Let :: Opt.Def -> Opt.Expr -> Opt.Expr`), `Names.generate`
  (already used throughout this file).
- Produces: nothing consumed by later tasks — this is the last code change in this plan; Task 4
  re-verifies against a real compiler build.

- [ ] **Step 1: Change `buildFusedCrossFold`'s signature to take the raw `optStep` instead of a pre-built `StepK`, and hoist it via `Opt.Let`**

Find this existing code (added in Task 1) in `compiler/src/Optimize/Expression.hs`:

```haskell
buildFusedCrossFold :: Hints -> Cycle -> StepK -> Opt.Expr -> [ListStage] -> CrossBase -> Names.Tracker Opt.Expr
buildFusedCrossFold hints cycle base initExpr stages crossBase =
  do  composed <- foldM (wrapStage hints cycle) base stages
      case crossBase of
        CBDictToList e  -> dictTerminator composed e (\k v -> Opt.Tuple k v Nothing)
        CBDictKeys e    -> dictTerminator composed e (\k _ -> k)
        CBDictValues e  -> dictTerminator composed e (\_ v -> v)
        CBSetToList e   -> singleArgTerminator ModuleName.set    composed e
        CBArrayToList e -> singleArgTerminator ModuleName.array composed e
  where
    dictTerminator composed e project =
      do  optE     <- optimize hints cycle e
          keyName  <- Names.generate
          valName  <- Names.generate
          accName  <- Names.generate
          body     <- composed (project (Opt.VarLocal keyName) (Opt.VarLocal valName)) (Opt.VarLocal accName)
          optFoldl <- Names.registerGlobal ModuleName.dict "foldl"
          pure $ Opt.Call optFoldl
            [ Opt.Function [keyName, valName, accName] body
            , initExpr
            , optE
            ]

    singleArgTerminator home composed e =
      do  optE     <- optimize hints cycle e
          elemName <- Names.generate
          accName  <- Names.generate
          body     <- composed (Opt.VarLocal elemName) (Opt.VarLocal accName)
          optFoldl <- Names.registerGlobal home "foldl"
          pure $ Opt.Call optFoldl
            [ Opt.Function [elemName, accName] body
            , initExpr
            , optE
            ]
```

Replace it with:

```haskell
-- `optStep` (the user's own step-function argument, already `optimize`d) used
-- to be passed pre-wrapped as a StepK (`baseStepK optStep`), which embeds a
-- fresh `Opt.Call optStep [...]` directly inside the per-element callback's
-- body. When `optStep` is itself a literal `Opt.Function` (the common case --
-- the user wrote an inline lambda), that nested call is a shape
-- Generate.JavaScript.Expression's call-site dispatch does not recognize (it
-- only special-cases Opt.VarGlobal/Opt.VarLocal callees with a known arity),
-- so it falls back to the generic A2 dispatch, re-wrapping the literal
-- Opt.Function in a fresh F2(...) closure on EVERY element -- strictly worse
-- than the unfused baseline, where the same lambda sits as List.foldl's
-- literal argument and gets the existing $unwrapped/no-wrap treatment for
-- free. Fix: bind `optStep` once via Opt.Let, outside the per-element
-- callback, and have the callback call the hoisted local instead. This
-- reuses the already-shipped extendWithLocalArity/generateDirectLocalCall
-- machinery unchanged: when optStep is a literal Opt.Function, the local's
-- arity gets recorded and calls to it compile to a direct .f(...) call (no
-- A2 at all); otherwise the hoist still avoids re-evaluating optStep once
-- per element. Confirmed by Task 2's real-compiler timing regression
-- (dictKeysFoldl/dictValuesFoldl/setToListFoldl/arrayToListFoldl were
-- 1.3x-1.4x SLOWER before this fix).
buildFusedCrossFold :: Hints -> Cycle -> Opt.Expr -> Opt.Expr -> [ListStage] -> CrossBase -> Names.Tracker Opt.Expr
buildFusedCrossFold hints cycle optStep initExpr stages crossBase =
  do  stepName <- Names.generate
      composed  <- foldM (wrapStage hints cycle) (baseStepK (Opt.VarLocal stepName)) stages
      result <- case crossBase of
        CBDictToList e  -> dictTerminator composed e (\k v -> Opt.Tuple k v Nothing)
        CBDictKeys e    -> dictTerminator composed e (\k _ -> k)
        CBDictValues e  -> dictTerminator composed e (\_ v -> v)
        CBSetToList e   -> singleArgTerminator ModuleName.set    composed e
        CBArrayToList e -> singleArgTerminator ModuleName.array composed e
      pure (Opt.Let (Opt.Def stepName optStep) result)
  where
    dictTerminator composed e project =
      do  optE     <- optimize hints cycle e
          keyName  <- Names.generate
          valName  <- Names.generate
          accName  <- Names.generate
          body     <- composed (project (Opt.VarLocal keyName) (Opt.VarLocal valName)) (Opt.VarLocal accName)
          optFoldl <- Names.registerGlobal ModuleName.dict "foldl"
          pure $ Opt.Call optFoldl
            [ Opt.Function [keyName, valName, accName] body
            , initExpr
            , optE
            ]

    singleArgTerminator home composed e =
      do  optE     <- optimize hints cycle e
          elemName <- Names.generate
          accName  <- Names.generate
          body     <- composed (Opt.VarLocal elemName) (Opt.VarLocal accName)
          optFoldl <- Names.registerGlobal home "foldl"
          pure $ Opt.Call optFoldl
            [ Opt.Function [elemName, accName] body
            , initExpr
            , optE
            ]
```

(Only the doc comment and the signature/body of `buildFusedCrossFold` itself changed — note `base`
is renamed `optStep` and its type changes from `StepK` to `Opt.Expr`; `dictTerminator`/
`singleArgTerminator` are textually identical to before, just now defined in a `where` attached to
the new body.)

- [ ] **Step 2: Update the call site to pass `optStep` directly instead of `baseStepK optStep`**

Find this existing guard (added in Task 1) in `compiler/src/Optimize/Expression.hs`:

```haskell
      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "foldl"
      , [stepArg, accArg, listArg] <- args
      , (stages, source) <- peelChain listArg
      , Just crossBase <- peelCrossBase source
      ->
          do  optStep <- optimize hints cycle stepArg
              optAcc  <- optimize hints cycle accArg
              buildFusedCrossFold hints cycle (baseStepK optStep) optAcc stages crossBase
```

Replace the last line with:

```haskell
      | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
      , home == ModuleName.list, name == "foldl"
      , [stepArg, accArg, listArg] <- args
      , (stages, source) <- peelChain listArg
      , Just crossBase <- peelCrossBase source
      ->
          do  optStep <- optimize hints cycle stepArg
              optAcc  <- optimize hints cycle accArg
              buildFusedCrossFold hints cycle optStep optAcc stages crossBase
```

(Only `(baseStepK optStep)` becomes `optStep` — nothing else on this line or around it changes.)

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
git commit -m "perf: hoist cross-container fusion's step function out of the per-element callback"
```

---

### Task 4: Re-verify against a real compiler build (structure, correctness, timing — confirm the fix resolves the regression)

**Files:**
- None in the repo — scratch artifacts outside the repo only, same as Task 2.

**Interfaces:**
- Consumes: the `elm` binary built in Task 3; the pre-Task-1 commit (same `BEFORE_SHA` derivation as
  Task 2 — the commit before Task 1's own perf commit, i.e. two perf commits back from HEAD now
  that Task 3 has landed: confirm by grepping for "CROSS-CONTAINER" in the candidate SHA's
  `compiler/src/Optimize/Expression.hs`, exactly as Task 2 already had to do).
- Produces: nothing — terminal verification task.

Repeat Task 2's Steps 1-2 (build "before"/"after" binaries — reuse the same `/tmp/elm-crosscontainer-bin`
naming if Task 2's artifacts were kept, or recreate them if Task 2's Step 9 cleanup already ran) and
Steps 3-7 (scratch project, compile, structural check, correctness check, Dev-mode check) exactly as
written in Task 2 — the `Bench.elm` fixture and all verification scripts are unchanged, since Task 3
does not change *what* fuses, only *how efficiently* the generated code runs. Then re-run Step 8's
timing table for all six functions and confirm:

- [ ] **Step 1: Re-run Task 2's Steps 1-8 verbatim against the Task-3 "after" binary**

- [ ] **Step 2: Confirm every function now shows a speedup, not just 2 of 6**

Expected, given Task 2's diagnosis: `dictKeysFoldl`, `dictValuesFoldl`, `setToListFoldl`,
`arrayToListFoldl` should flip from ~0.7-0.8x (slower) to a real speedup (not necessarily matching
the original spike's 1.16x-3.15x band exactly, since the spike didn't account for this codegen
overhead either way — any consistent speedup >1.0x, reproduced across repeated interleaved runs,
counts as resolving the regression). `dictToListFoldl` and `chainedDictToListFoldl` (already
winning before this fix) should stay at least as fast as Task 2 measured, ideally faster still
(same fix applies to their step call too).

**If any function still regresses:** do not guess further fixes — report the exact generated JS for
that function's fused body (structural check output plus a manual read of the relevant function in
`after-prod.js`) so the controller can decide whether this needs the deeper (`wrapStage`-level, out
of this plan's scope per Task 3's own scoping note) fix or a scope reduction instead.

- [ ] **Step 3: Clean up scratch artifacts** (same as Task 2 Step 9, plus anything Task 4 created new)

No commit for this task — it's verification only, produces no repo changes.
