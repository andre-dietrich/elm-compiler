# Decision-Tree DAG Sharing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Optimize.Case.optimize` merge case-arms whose pattern binds no variable and whose
(already-optimized) body is structurally identical, into a single shared target index, so the
existing `countTargets`/`createChoices`/`Opt.Jump` mechanism compiles their shared code once instead
of once per arm.

**Architecture:** Replace `Optimize/Case.hs`'s `indexify` step (which today gives every case-arm its
own fresh target index unconditionally) with `assignTargets`, which reuses an earlier target when a
later arm's variable-free body is equal (by a new, hand-written, conservative `sameExpr`) to an
earlier variable-free arm's body. Nothing else in the file changes, no other file changes, and
`Case.optimize`'s external signature is untouched.

**Tech Stack:** Haskell (GHC 9.8.4 via the project's Docker toolchain); Elm 0.19.2 scratch fixtures;
Node.js for executing compiled output and benchmarking.

## Known scope caveat

This plan merges **leaf bodies only** (the value at the end of a matched arm), within a single
flattened decision tree. It does not deduplicate a repeated *test/dispatch structure* (e.g. a
nested `case priority of ...` written out verbatim under several outer arms, which compiles to
several separate `Opt.Case` AST nodes, one per outer arm — explicitly out of scope, see the design
spec's Non-goals). The [[decision-tree-dag-sharing-spike]]'s hand-patch description ("5-fold
duplicated Inner switch merged into one sharedInner function") reads like it may have been
simulating exactly that separate-AST-node scenario, not the single-flattened-tree scenario this plan
targets — meaning this plan's real-compiler speedup (measured in Task 5) may come in well under the
spike's 1.40x-1.46x, since here only the constant leaf value is shared, not the repeated comparison
work. Treat Task 5's measurement as the actual verdict, not a formality — if it comes back near 1.0x,
that is a legitimate, useful (if disappointing) result, and the nested-case-of-case scenario would be
a distinct, larger follow-up design, not a bug in this implementation.

## Global Constraints

- No automated test suite exists in this repository. Every task's "test" step is: build the
  compiler in the Docker toolchain (fails loudly on any warning, since `-Wall -Werror` is baked into
  `elm.cabal`), then exercise it against a hand-written scratch Elm fixture and inspect/execute the
  generated JS. This is the project's established verification pattern (see `CLAUDE.md`).
- Build recipe (from `CLAUDE.md`):
  ```bash
  docker run --rm -v "$PWD":/work -w /work \
    -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
    haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
      cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
  ```
- Run recipe against a scratch project (from `CLAUDE.md`) — `<scratch-dir>` and `<elm-home-dir>` are
  host paths you choose (use a fresh directory under your session scratchpad, never a path inside
  this repo):
  ```bash
  docker run --rm -v "$PWD":/work -w /work \
    -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
    -v <scratch-dir>:/test -v <elm-home-dir>:/root/.elm \
    haskell:9.8.4 bash -c 'BIN=$(export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal list-bin elm); cd /test && $BIN make src/Main.elm --output=main.js'
  ```
  Add `--optimize` to the final `$BIN make ...` invocation for a Prod build.
- Every scratch fixture's `elm.json` must declare `"elm-version": "0.19.2"`.
- Never mount a real project directory from this repo as `/test` — `elm make` writes root-owned
  `elm-stuff/` artifacts into whatever is mounted there.
- Only `compiler/src/Optimize/Case.hs` is modified by this plan. No other file in the repo changes.

---

### Task 1: Implement `assignTargets`/`sameExpr` in `Optimize/Case.hs` and build

**Files:**
- Modify: `compiler/src/Optimize/Case.hs` (full rewrite of the file's content, shown below)

**Interfaces:**
- Produces: `Optimize.Case.optimize :: Name.Name -> Name.Name -> [(Can.Pattern, Opt.Expr)] ->
  Opt.Expr` — signature unchanged from today; only its internal target-assignment step changes.
  Nothing outside this file calls anything else from it (`optimize` is the module's only export).

- [ ] **Step 1: Replace the full contents of `compiler/src/Optimize/Case.hs`**

```haskell
module Optimize.Case
  ( optimize
  )
  where


import Control.Arrow (second)
import Data.List (foldl')
import qualified Data.Map as Map
import Data.Map ((!))
import qualified Data.Maybe as Maybe
import qualified Data.Name as Name

import qualified AST.Canonical as Can
import qualified AST.Optimized as Opt
import qualified Optimize.DecisionTree as DT
import qualified Reporting.Annotation as A



-- OPTIMIZE A CASE EXPRESSION


optimize :: Name.Name -> Name.Name -> [(Can.Pattern, Opt.Expr)] -> Opt.Expr
optimize temp root optBranches =
  let
    (patterns, indexedBranches) =
      assignTargets optBranches

    decider = treeToDecider (DT.compile patterns)
    targetCounts = countTargets decider

    (choices, maybeJumps) =
        unzip (map (createChoices targetCounts) indexedBranches)
  in
  Opt.Case temp root
    (insertChoices (Map.fromList choices) decider)
    (Maybe.catMaybes maybeJumps)



-- ASSIGN TARGETS
--
-- Every case-arm needs a target index for DT.compile. Normally that would
-- just be its position (0, 1, 2, ...). But when two or more arms have a
-- pattern that binds no variable and an (already-optimized) body that is
-- structurally identical, they are given the SAME target index instead of
-- fresh ones -- letting the existing countTargets/createChoices/Opt.Jump
-- mechanism (below, unmodified) share the compiled code between them,
-- exactly the way it already shares code for any target reached by 2+
-- leaves today. See the design spec
-- (docs/superpowers/specs/2026-07-22-decision-tree-dag-sharing-design.md)
-- for why this is only safe when neither arm's pattern binds a variable.


assignTargets :: [(Can.Pattern, Opt.Expr)] -> ([(Can.Pattern, Int)], [(Int, Opt.Expr)])
assignTargets optBranches =
  let
    (patternsRev, branchesRev, _, _) =
      foldl' assignTarget ([], [], [], 0) optBranches
  in
  (reverse patternsRev, reverse branchesRev)


type Seen = [(Opt.Expr, Int)]


assignTarget
    :: ([(Can.Pattern, Int)], [(Int, Opt.Expr)], Seen, Int)
    -> (Can.Pattern, Opt.Expr)
    -> ([(Can.Pattern, Int)], [(Int, Opt.Expr)], Seen, Int)
assignTarget (patternsAcc, branchesAcc, seen, nextFresh) (pattern, branch) =
  case findSharedTarget seen pattern branch of
    Just target ->
      ( (pattern, target) : patternsAcc
      , branchesAcc
      , seen
      , nextFresh
      )

    Nothing ->
      let
        newSeen =
          if bindsNoVariables pattern then
            (branch, nextFresh) : seen
          else
            seen
      in
      ( (pattern, nextFresh) : patternsAcc
      , (nextFresh, branch) : branchesAcc
      , newSeen
      , nextFresh + 1
      )


findSharedTarget :: Seen -> Can.Pattern -> Opt.Expr -> Maybe Int
findSharedTarget seen pattern branch =
  if bindsNoVariables pattern then
    Maybe.listToMaybe
      [ target | (seenBranch, target) <- seen, sameExpr branch seenBranch ]
  else
    Nothing



-- BINDS NO VARIABLES
--
-- Only a pattern that binds nothing at all is safe to merge: a variable
-- bound by one arm's pattern might be extracted from a different sub-
-- position than the "same" name bound by another arm's pattern, so sharing
-- a body that reads such a variable could read the wrong value. A body
-- reached through a variable-free pattern can't depend on which arm
-- reached it, so merging two such equal bodies is always sound.


bindsNoVariables :: Can.Pattern -> Bool
bindsNoVariables (A.At _ pattern) =
  case pattern of
    Can.PAnything ->
      True

    Can.PVar _ ->
      False

    Can.PRecord _ ->
      False

    Can.PAlias _ _ ->
      False

    Can.PUnit ->
      True

    Can.PTuple a b maybeC ->
      bindsNoVariables a && bindsNoVariables b && maybe True bindsNoVariables maybeC

    Can.PList ps ->
      all bindsNoVariables ps

    Can.PCons hd tl ->
      bindsNoVariables hd && bindsNoVariables tl

    Can.PBool _ _ ->
      True

    Can.PChr _ ->
      True

    Can.PStr _ ->
      True

    Can.PInt _ ->
      True

    Can.PCtor _ _ _ _ _ args ->
      all (bindsNoVariables . argPattern) args


argPattern :: Can.PatternCtorArg -> Can.Pattern
argPattern (Can.PatternCtorArg _ _ pattern) =
  pattern



-- SAME EXPR
--
-- A hand-written, deliberately conservative structural equality over
-- already-optimized Opt.Expr, used only to decide whether two variable-
-- free branch bodies are worth merging. It only knows about constructors
-- that can appear in such a body without introducing a new binding
-- (literals, variable/global references, calls, tuples, lists, if, field
-- access); everything else (Let, Destruct, Case, Function, the TailCall
-- variants, Update, Record, Shader, PrimOp, ...) always compares unequal,
-- even to itself. Returning False only ever misses a sharing opportunity;
-- it can never cause an incorrect merge.


sameExpr :: Opt.Expr -> Opt.Expr -> Bool
sameExpr expr1 expr2 =
  case (expr1, expr2) of
    (Opt.Bool a, Opt.Bool b) ->
      a == b

    (Opt.Chr a, Opt.Chr b) ->
      a == b

    (Opt.Str a, Opt.Str b) ->
      a == b

    (Opt.Int a, Opt.Int b) ->
      a == b

    (Opt.Float a, Opt.Float b) ->
      a == b

    (Opt.Unit, Opt.Unit) ->
      True

    (Opt.VarLocal a, Opt.VarLocal b) ->
      a == b

    (Opt.VarGlobal g1, Opt.VarGlobal g2) ->
      sameGlobal g1 g2

    (Opt.VarEnum g1 i1, Opt.VarEnum g2 i2) ->
      sameGlobal g1 g2 && i1 == i2

    (Opt.VarBox g1, Opt.VarBox g2) ->
      sameGlobal g1 g2

    (Opt.VarKernel h1 a, Opt.VarKernel h2 b) ->
      h1 == h2 && a == b

    (Opt.List xs1, Opt.List xs2) ->
      sameExprList xs1 xs2

    (Opt.Call f1 args1, Opt.Call f2 args2) ->
      sameExpr f1 f2 && sameExprList args1 args2

    (Opt.If branches1 final1, Opt.If branches2 final2) ->
      sameBranchList branches1 branches2 && sameExpr final1 final2

    (Opt.Accessor a, Opt.Accessor b) ->
      a == b

    (Opt.Access e1 a, Opt.Access e2 b) ->
      sameExpr e1 e2 && a == b

    (Opt.Tuple a1 b1 c1, Opt.Tuple a2 b2 c2) ->
      sameExpr a1 a2 && sameExpr b1 b2 && sameMaybeExpr c1 c2

    _ ->
      False


sameGlobal :: Opt.Global -> Opt.Global -> Bool
sameGlobal (Opt.Global h1 n1) (Opt.Global h2 n2) =
  h1 == h2 && n1 == n2


sameExprList :: [Opt.Expr] -> [Opt.Expr] -> Bool
sameExprList exprs1 exprs2 =
  case (exprs1, exprs2) of
    ([], []) ->
      True

    (e1 : rest1, e2 : rest2) ->
      sameExpr e1 e2 && sameExprList rest1 rest2

    _ ->
      False


sameMaybeExpr :: Maybe Opt.Expr -> Maybe Opt.Expr -> Bool
sameMaybeExpr maybeExpr1 maybeExpr2 =
  case (maybeExpr1, maybeExpr2) of
    (Nothing, Nothing) ->
      True

    (Just e1, Just e2) ->
      sameExpr e1 e2

    _ ->
      False


sameBranchList :: [(Opt.Expr, Opt.Expr)] -> [(Opt.Expr, Opt.Expr)] -> Bool
sameBranchList branches1 branches2 =
  case (branches1, branches2) of
    ([], []) ->
      True

    ((c1, b1) : rest1, (c2, b2) : rest2) ->
      sameExpr c1 c2 && sameExpr b1 b2 && sameBranchList rest1 rest2

    _ ->
      False



-- TREE TO DECIDER
--
-- Decision trees may have some redundancies, so we convert them to a Decider
-- which has special constructs to avoid code duplication when possible.


treeToDecider :: DT.DecisionTree -> Opt.Decider Int
treeToDecider tree =
  case tree of
    DT.Match target ->
        Opt.Leaf target

    -- zero options
    DT.Decision _ [] Nothing ->
        error "compiler bug, somehow created an empty decision tree"

    -- one option
    DT.Decision _ [(_, subTree)] Nothing ->
        treeToDecider subTree

    DT.Decision _ [] (Just subTree) ->
        treeToDecider subTree

    -- two options
    DT.Decision path [(test, successTree)] (Just failureTree) ->
        toChain path test successTree failureTree

    DT.Decision path [(test, successTree), (_, failureTree)] Nothing ->
        toChain path test successTree failureTree

    -- many options
    DT.Decision path edges Nothing ->
        let
          (necessaryTests, fallback) =
              (init edges, snd (last edges))
        in
          Opt.FanOut
            path
            (map (second treeToDecider) necessaryTests)
            (treeToDecider fallback)

    DT.Decision path edges (Just fallback) ->
        Opt.FanOut path (map (second treeToDecider) edges) (treeToDecider fallback)


toChain :: DT.Path -> DT.Test -> DT.DecisionTree -> DT.DecisionTree -> Opt.Decider Int
toChain path test successTree failureTree =
  let
    failure =
      treeToDecider failureTree
  in
    case treeToDecider successTree of
      Opt.Chain testChain success subFailure | failure == subFailure ->
          Opt.Chain ((path, test) : testChain) success failure

      success ->
          Opt.Chain [(path, test)] success failure



-- INSERT CHOICES
--
-- If a target appears exactly once in a Decider, the corresponding expression
-- can be inlined. Whether things are inlined or jumps is called a "choice".


countTargets :: Opt.Decider Int -> Map.Map Int Int
countTargets decisionTree =
  case decisionTree of
    Opt.Leaf target ->
        Map.singleton target 1

    Opt.Chain _ success failure ->
        Map.unionWith (+) (countTargets success) (countTargets failure)

    Opt.FanOut _ tests fallback ->
        Map.unionsWith (+) (map countTargets (fallback : map snd tests))


createChoices
    :: Map.Map Int Int
    -> (Int, Opt.Expr)
    -> ( (Int, Opt.Choice), Maybe (Int, Opt.Expr) )
createChoices targetCounts (target, branch) =
    if targetCounts ! target == 1 then
        ( (target, Opt.Inline branch)
        , Nothing
        )

    else
        ( (target, Opt.Jump target)
        , Just (target, branch)
        )


insertChoices
    :: Map.Map Int Opt.Choice
    -> Opt.Decider Int
    -> Opt.Decider Opt.Choice
insertChoices choiceDict decider =
  let
    go =
      insertChoices choiceDict
  in
    case decider of
      Opt.Leaf target ->
          Opt.Leaf (choiceDict ! target)

      Opt.Chain testChain success failure ->
          Opt.Chain testChain (go success) (go failure)

      Opt.FanOut path tests fallback ->
          Opt.FanOut path (map (second go) tests) (go fallback)
```

- [ ] **Step 2: Build the compiler**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds (exit code 0), no warnings (the project's `-Wall -Werror` turns any warning
— e.g. an incomplete pattern match in `sameExpr`/`bindsNoVariables`, or an unused import/binding —
into a build failure). If it fails on a warning, fix the specific reported line and rebuild; do not
suppress the warning.

- [ ] **Step 3: Commit**

```bash
git add compiler/src/Optimize/Case.hs
git commit -m "perf(codegen): merge identical variable-free case-arm bodies to a shared target"
```

---

### Task 2: Motivating-case fixture — confirm sharing actually happens

**Files:**
- Create (scratch, not committed): `<scratchpad>/dag-sharing-fixtures/motivating/elm.json`,
  `<scratchpad>/dag-sharing-fixtures/motivating/src/Main.elm`,
  `<scratchpad>/dag-sharing-fixtures/motivating/run.js`

**Interfaces:**
- Consumes: the `elm` binary built in Task 1 (via `cabal list-bin elm` inside the same Docker image).
- Produces: nothing further tasks depend on — this task's evidence is its own console output.

- [ ] **Step 1: Write the scratch fixture**

`elm.json`:

```json
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": {
            "elm/core": "1.0.5"
        },
        "indirect": {}
    },
    "test-dependencies": {
        "direct": {},
        "indirect": {}
    }
}
```

`src/Main.elm`:

```elm
port module Main exposing (main)

import Platform


type Status
    = Pending
    | Active
    | Done


type Priority
    = Low
    | Medium
    | High


classify : Status -> Priority -> String
classify status priority =
    case ( status, priority ) of
        ( Pending, Low ) ->
            "wait"

        ( Pending, Medium ) ->
            "wait soon"

        ( Pending, High ) ->
            "urgent wait"

        ( Active, Low ) ->
            "wait"

        ( Active, Medium ) ->
            "wait soon"

        ( Active, High ) ->
            "urgent wait"

        ( Done, _ ) ->
            "done"


allResults : List String
allResults =
    [ classify Pending Low
    , classify Pending Medium
    , classify Pending High
    , classify Active Low
    , classify Active Medium
    , classify Active High
    , classify Done Low
    , classify Done High
    ]


port results : List String -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), results allResults )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

`run.js`:

```js
const { Elm } = require("./main.js");

const app = Elm.Main.init();

app.ports.results.subscribe(function (results) {
  console.log(JSON.stringify(results));
});
```

- [ ] **Step 2: Compile with `--optimize` and run under Node**

Substitute `<scratch-dir>` with the absolute path to the `motivating/` directory from Step 1, and
`<elm-home-dir>` with any fresh empty host directory (first compile needs network access to fetch
`elm/core`):

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v <scratch-dir>:/test -v <elm-home-dir>:/root/.elm \
  haskell:9.8.4 bash -c 'BIN=$(export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal list-bin elm); cd /test && $BIN make src/Main.elm --optimize --output=main.js'

cd <scratch-dir> && node run.js
```

Expected stdout:
```
["wait","wait soon","urgent wait","wait","wait soon","urgent wait","done","done"]
```

If this doesn't match, the merge introduced a correctness bug — stop and debug before continuing
(do not proceed to benchmarking a broken compiler).

- [ ] **Step 3: Confirm the sharing actually happened**

```bash
grep -c '"wait"' <scratch-dir>/main.js
```

Expected: `1` (the string literal `"wait"` appears exactly once in the compiled output — shared
between the `Pending` and `Active` arms — not twice). If it's `2`, the merge did not fire; re-check
Task 1's `sameExpr`/`bindsNoVariables` logic (a common mistake: the two `"wait"` bodies must be
`Opt.Str` values compared via `sameExpr`'s `(Opt.Str a, Opt.Str b) -> a == b` case — confirm this
clause is present and reachable).

- [ ] **Step 4: Repeat Steps 2-3 without `--optimize` (Dev mode)**

Same commands, dropping `--optimize` from the `elm make` invocation and re-running `node run.js`.
Expected: same JSON output as Step 2, and the same `grep -c '"wait"' main.js` result of `1` — this
transformation runs identically in Dev and Prod since it happens in `Optimize.Case`, before
`Generate.Mode` is ever consulted.

---

### Task 3: Correctness-invariant fixture — confirm variable-binding arms are never merged

**Files:**
- Create (scratch, not committed): `<scratchpad>/dag-sharing-fixtures/invariant/elm.json`,
  `<scratchpad>/dag-sharing-fixtures/invariant/src/Main.elm`,
  `<scratchpad>/dag-sharing-fixtures/invariant/run.js`

**Interfaces:**
- Consumes: the `elm` binary built in Task 1.
- Produces: nothing further tasks depend on.

- [ ] **Step 1: Write the scratch fixture**

`elm.json`: identical to Task 2's Step 1 `elm.json`.

`src/Main.elm` — two arms bind the *same variable name* at *different structural positions*
(`First _ x` extracts `x` from the second field of a 2-field constructor; `Second x` extracts `x`
from the only field of a 1-field constructor), with textually-identical bodies. If a hypothetical
buggy implementation dropped the `bindsNoVariables` guard and merged these purely by body-text
similarity, the shared body would read `x` via the wrong extraction path for one of the two arms:

```elm
port module Main exposing (main)

import Platform


type Wrapper
    = First Int Int
    | Second Int


read : Wrapper -> String
read wrapper =
    case wrapper of
        First _ x ->
            "value:" ++ String.fromInt x

        Second x ->
            "value:" ++ String.fromInt x


allResults : List String
allResults =
    [ read (First 99 4)
    , read (Second 5)
    ]


port results : List String -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), results allResults )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

`run.js`: identical to Task 2's Step 1 `run.js`.

- [ ] **Step 2: Compile with `--optimize` and run under Node**

Same Docker commands as Task 2 Step 2, pointed at this fixture's directory.

Expected stdout:
```
["value:4","value:5"]
```

`First 99 4` must print `"value:4"` (reading its *second* argument), not `"value:99"` — if it prints
`"value:99"`, the two arms' extraction paths were swapped by an incorrect merge, which would be a
serious correctness bug: stop and re-check that `bindsNoVariables` returns `False` for `PVar`/for any
pattern containing one (both `First _ x` and `Second x` bind `x`, so `bindsNoVariables` must return
`False` for both, and `findSharedTarget` must therefore never even attempt a match for either arm).

- [ ] **Step 3: Repeat Step 2 without `--optimize` (Dev mode)**

Same expected output: `["value:4","value:5"]`.

---

### Task 4: No-duplication regression fixture — confirm unrelated cases are unaffected

**Files:**
- Create (scratch, not committed): `<scratchpad>/dag-sharing-fixtures/regression/elm.json`,
  `<scratchpad>/dag-sharing-fixtures/regression/src/Main.elm`,
  `<scratchpad>/dag-sharing-fixtures/regression/run.js`

**Interfaces:**
- Consumes: the `elm` binary built in Task 1, and (for comparison) an `elm` binary built from the
  commit *before* Task 1's change (see Step 2).
- Produces: nothing further tasks depend on.

- [ ] **Step 1: Write the scratch fixture**

`elm.json`: identical to Task 2's Step 1 `elm.json`.

`src/Main.elm` — every arm's body is distinct, so no merging should ever be triggered:

```elm
port module Main exposing (main)

import Platform


classifyNumber : Int -> String
classifyNumber n =
    case n of
        0 ->
            "zero"

        1 ->
            "one"

        _ ->
            "many"


allResults : List String
allResults =
    [ classifyNumber 0
    , classifyNumber 1
    , classifyNumber 2
    ]


port results : List String -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), results allResults )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

`run.js`: identical to Task 2's Step 1 `run.js`.

- [ ] **Step 2: Build the pre-change compiler binary for comparison**

```bash
git worktree add <scratchpad>/dag-sharing-fixtures/pre-change-worktree HEAD~1
docker run --rm -v "<scratchpad>/dag-sharing-fixtures/pre-change-worktree":/work -w /work \
  -v elm-cabal-home-prechange:/root/.cabal -v elm-dist-prechange:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

(`HEAD~1` is the commit immediately before Task 1 Step 3's commit — adjust if other commits landed
in between. Using separate named volumes, `elm-cabal-home-prechange`/`elm-dist-prechange`, avoids
clobbering the post-change build's cached artifacts from Task 1.)

- [ ] **Step 3: Compile the fixture with both compilers and diff**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v <scratch-dir>:/test -v <elm-home-dir>:/root/.elm \
  haskell:9.8.4 bash -c 'BIN=$(export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal list-bin elm); cd /test && $BIN make src/Main.elm --optimize --output=main-after.js'

docker run --rm -v "<scratchpad>/dag-sharing-fixtures/pre-change-worktree":/work -w /work \
  -v elm-cabal-home-prechange:/root/.cabal -v elm-dist-prechange:/work/dist-newstyle \
  -v <scratch-dir>:/test -v <elm-home-dir>:/root/.elm \
  haskell:9.8.4 bash -c 'BIN=$(export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal list-bin elm); cd /test && $BIN make src/Main.elm --optimize --output=main-before.js'

diff <scratch-dir>/main-before.js <scratch-dir>/main-after.js
```

Expected: no output from `diff` (the files are byte-identical) — a case with no mergeable
duplication must produce exactly the same generated JS as before this change.

- [ ] **Step 4: Run the fixture and confirm output**

```bash
cd <scratch-dir> && node -e 'const {Elm}=require("./main-after.js"); const app=Elm.Main.init(); app.ports.results.subscribe(r=>console.log(JSON.stringify(r)));'
```

Expected: `["zero","one","many"]`.

- [ ] **Step 5: Remove the comparison worktree**

```bash
git worktree remove <scratchpad>/dag-sharing-fixtures/pre-change-worktree
```

---

### Task 5: Benchmark the real compiler output for the motivating case

**Files:**
- Create (scratch, not committed): `<scratchpad>/dag-sharing-fixtures/benchmark/elm.json`,
  `<scratchpad>/dag-sharing-fixtures/benchmark/src/Main.elm`,
  `<scratchpad>/dag-sharing-fixtures/benchmark/bench-runner.js`

**Interfaces:**
- Consumes: the post-change `elm` binary from Task 1, and the pre-change `elm` binary built the same
  way as Task 4 Step 2 (reuse that worktree/build if it still exists, otherwise recreate it).
- Produces: a console report of measured speedup — the final evidence this plan set out to gather
  (per [[decision-tree-dag-sharing-spike]]'s 1.40x-1.46x hand-patched finding).

- [ ] **Step 1: Write a larger version of the motivating fixture**

A wider union (10 outer values sharing one inner 5-way dispatch, matching the spike's fixture scale)
called in a loop, with the loop count taken from `process.argv` via a port so the same compiled JS
can be benchmarked at multiple sizes without recompiling:

`elm.json`: identical to Task 2's Step 1 `elm.json`.

`src/Main.elm`:

```elm
port module Main exposing (main)

import Platform


type Outer
    = O0
    | O1
    | O2
    | O3
    | O4
    | O5
    | O6
    | O7
    | O8
    | O9


type Inner
    = I0
    | I1
    | I2
    | I3
    | I4


dispatch : Outer -> Inner -> Int
dispatch outer inner =
    case ( outer, inner ) of
        ( O0, I0 ) -> 1
        ( O0, I1 ) -> 2
        ( O0, I2 ) -> 3
        ( O0, I3 ) -> 4
        ( O0, I4 ) -> 5
        ( O1, I0 ) -> 1
        ( O1, I1 ) -> 2
        ( O1, I2 ) -> 3
        ( O1, I3 ) -> 4
        ( O1, I4 ) -> 5
        ( O2, I0 ) -> 1
        ( O2, I1 ) -> 2
        ( O2, I2 ) -> 3
        ( O2, I3 ) -> 4
        ( O2, I4 ) -> 5
        ( O3, I0 ) -> 1
        ( O3, I1 ) -> 2
        ( O3, I2 ) -> 3
        ( O3, I3 ) -> 4
        ( O3, I4 ) -> 5
        ( O4, I0 ) -> 1
        ( O4, I1 ) -> 2
        ( O4, I2 ) -> 3
        ( O4, I3 ) -> 4
        ( O4, I4 ) -> 5
        ( O5, I0 ) -> 1
        ( O5, I1 ) -> 2
        ( O5, I2 ) -> 3
        ( O5, I3 ) -> 4
        ( O5, I4 ) -> 5
        ( O6, I0 ) -> 1
        ( O6, I1 ) -> 2
        ( O6, I2 ) -> 3
        ( O6, I3 ) -> 4
        ( O6, I4 ) -> 5
        ( O7, I0 ) -> 1
        ( O7, I1 ) -> 2
        ( O7, I2 ) -> 3
        ( O7, I3 ) -> 4
        ( O7, I4 ) -> 5
        ( O8, I0 ) -> 1
        ( O8, I1 ) -> 2
        ( O8, I2 ) -> 3
        ( O8, I3 ) -> 4
        ( O8, I4 ) -> 5
        ( O9, I0 ) -> 1
        ( O9, I1 ) -> 2
        ( O9, I2 ) -> 3
        ( O9, I3 ) -> 4
        ( O9, I4 ) -> 5


outers : List Outer
outers =
    [ O0, O1, O2, O3, O4, O5, O6, O7, O8, O9 ]


inners : List Inner
inners =
    [ I0, I1, I2, I3, I4 ]


runChecksum : Int -> Int
runChecksum reps =
    let
        oneSweep acc =
            List.foldl
                (\o accO ->
                    List.foldl (\i accI -> (accI * 31 + dispatch o i) |> modBy 1000000007) accO inners
                )
                acc
                outers
    in
    List.foldl (\_ acc -> oneSweep acc) 0 (List.range 1 reps)


port checksum : Int -> Cmd msg


main : Program Int Int Int
main =
    Platform.worker
        { init = \reps -> ( 0, checksum (runChecksum reps) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

`bench-runner.js` — spawns the compiled program as a child process with a given `reps` flag value
and reports wall-clock time (mirroring the spike's separate-process methodology; see
[[decision-tree-dag-sharing-spike]]):

```js
const reps = parseInt(process.argv[2], 10);
const { Elm } = require(process.argv[3]);

const start = process.hrtime.bigint();

const app = Elm.Main.init({ flags: reps });

app.ports.checksum.subscribe(function (checksum) {
  const end = process.hrtime.bigint();
  const ms = Number(end - start) / 1e6;
  console.log(JSON.stringify({ checksum: checksum, ms: ms }));
});
```

Invoked as `node bench-runner.js <reps> <path-to-compiled-file>`, e.g. `node bench-runner.js 1000000
./main-before.js`.

- [ ] **Step 2: Compile the fixture with both the pre-change and post-change compilers**

Reuse (or recreate, per Task 4 Step 2) the `pre-change-worktree`. Compile this fixture's
`src/Main.elm --optimize` with each compiler into two separately-named output files,
`main-before.js` and `main-after.js`, in the same fixture directory (same Docker command shape as
Task 4 Step 3, changing only `--output`).

- [ ] **Step 3: Run both interleaved across several rep counts, comparing checksums and timing**

Calibrate `reps` so a single process run takes roughly 500ms-1s (per the spike's own lesson about
too-short runs producing false positives — see [[html-tag-arity-spike]]); start by trying `reps`
values of `100000`, `1000000`, and `5000000` and adjust based on the observed `ms` from a couple of
throwaway runs. `bench-runner.js` as written in Step 1 takes the file to benchmark as its third
argument (`process.argv[3]`, via `require(process.argv[3])`), so the same script benchmarks either
compiled file without editing it. For each `reps` size, run 6 interleaved runs (before, after,
before, after, before, after), discarding the first pair as warmup:

```bash
for i in 1 2 3 4 5 6; do
  if [ $((i % 2)) -eq 0 ]; then FILE=./main-before.js; else FILE=./main-after.js; fi
  node bench-runner.js 1000000 "$FILE"
done
```

Confirm every run's `checksum` field is identical across all `main-before.js`/`main-after.js` runs
at a given `reps` value (this is the correctness check — if checksums differ, stop, do not trust any
timing number, and go back to Task 2/3's fixtures to find what's wrong first). Then compare the
median `ms` for `main-before.js` vs `main-after.js` at each size (discarding the warmup pair) and
report the ratio (`before-ms / after-ms`) as the observed speedup.

- [ ] **Step 4: Record the result**

Note the observed speedup at each tested size in the commit message or a follow-up note (not a new
file — see Task 6). A result broadly consistent with the spike's 1.40x-1.46x is confirmation; a
result close to 1.0x (no measurable improvement) or worse means something about the real compiler's
code path differs from the hand-patch simulation and is worth a closer look before considering this
plan's goal met — but do not block on hitting an exact number, since the real compiler's output
naturally differs in details (e.g. actual field-name shortening, arity bypass) from a hand patch.

---

### Task 6: Record the outcome in memory

**Files:**
- Create: memory file in the auto-memory directory (`/home/andre/.claude/projects/-home-andre-Workspace-Projects-Freinet-elm-compiler/memory/decision-tree-dag-sharing-plan.md`)
- Modify: `/home/andre/.claude/projects/-home-andre-Workspace-Projects-Freinet-elm-compiler/memory/MEMORY.md` (append one line)

**Interfaces:**
- Consumes: the build/test/benchmark results from Tasks 1-5.
- Produces: a durable record of what shipped, for future sessions (mirrors the existing
  `decision-tree-dag-sharing-spike.md` memory entry's format).

- [ ] **Step 1: Write the memory file**

Write `decision-tree-dag-sharing-plan.md` with frontmatter:

```markdown
---
name: decision-tree-dag-sharing-plan
description: "Case-arm body merging (variable-free patterns, structural Opt.Expr equality) implemented in Optimize.Case.optimize's assignTargets, replacing indexify; reuses existing countTargets/createChoices/Opt.Jump machinery unmodified. No AST.Optimized/.elmo changes. Committed <commit-hash>."
metadata:
  type: project
---
```

followed by a short account (Ausgangspunkt/Vorgehen/Ergebnis in this project's established style —
see `decision-tree-dag-sharing-spike.md` for the tone) covering: the two design pivots this plan
went through before landing (Decider-Int-subtree comparison can't work → Can.Expr-level merge in
Expression.hs → final: Opt.Expr-level merge inside Case.hs's own indexify replacement), the
`bindsNoVariables` correctness restriction, and the Task 5 benchmark result.

- [ ] **Step 2: Update `MEMORY.md`**

Append one line:

```
- [Decision-Tree-DAG-Sharing (real)](decision-tree-dag-sharing-plan.md) — case-arm body merging in Optimize.Case, no format changes, committed <commit-hash>
```
