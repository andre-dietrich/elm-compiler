# Local/Lambda Direct-Call Bypass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing known-arity direct-call bypass (currently globals only) to local `let`-bound named functions, so calls to them skip the generic `A2..A9` arity-dispatch helpers and call `.f` directly.

**Architecture:** Thread a new `Map Name.Name Int` of "locally in-scope, known-arity" bindings through `Generate.Mode`, populated top-down as `Opt.Let` nodes are generated in `Generate.JavaScript.Expression`, and consulted by a new branch in `generateCall` alongside the existing `Opt.VarGlobal` arity check.

**Tech Stack:** Haskell (GHC 9.8.4, `cabal`), compiled inside the `haskell:9.8.4` Docker image per this repo's build recipe. Verification is manual (no automated test suite in this repo).

## Global Constraints

- Applies to `Mode.Prod` only. `Mode.Dev` JS output must be byte-identical before and after this change — this is a hard project invariant (see `CLAUDE.md`: "`Mode.Prod`-specific codegen must never change output for `Mode.Dev`").
- No automated test suite exists in this repo. Verification is: build the compiler, run it against a scratch `.elm` project, inspect generated JS, and execute it under Node (`CLAUDE.md`).
- `-Wall -Werror` is baked into `elm.cabal`'s `ghc-options` — any GHC warning (unused binds/imports, incomplete patterns) fails the build, including during iteration.
- Build via Docker (`haskell:9.8.4`) with named volumes (`elm-cabal-home`, `elm-dist`) so cabal's store and `dist-newstyle` persist across runs; use `--ghc-options=-O0` for the iteration loop per `CLAUDE.md`.
- v1 scope only: named `Def`/`TailDef`/`TailDefCons` local bindings. No support for destructured function values, no forward/mutual-peer arity propagation within the same `let`-chain (sequential top-down visibility only), and no change to `F2..F9` wrapper allocation at the definition site — only call sites change. See `docs/superpowers/specs/2026-07-03-local-arity-call-bypass-design.md` for the full rationale.

---

### Task 1: Capture baseline (pre-change) compiler output

**Files:**
- Create (host, outside the repo): `/tmp/elm-local-arity/src/Main.elm`
- Create (host, outside the repo): `/tmp/elm-local-arity/elm.json`
- Create (host, outside the repo): `/tmp/elm-local-arity/baseline/` (output directory for captured JS + Node run transcript)

**Interfaces:**
- Consumes: the `elm` binary built from the repo at its current (pre-change) commit.
- Produces: `/tmp/elm-local-arity/baseline/dev.js`, `/tmp/elm-local-arity/baseline/prod.js`, `/tmp/elm-local-arity/baseline/node-output.txt` — the "before" snapshot that Task 4 diffs against.

This scratch project exercises four shapes from the design doc: a plain local helper called twice (Case A), a `TailDef` loop kicked off from outside its own body (Case B), a local function called both fully-saturated and partially-applied (proving the bypass's `arity == length args` guard correctly leaves undersaturated calls alone), and forward/mutual local recursion (which the v1 design explicitly does *not* accelerate — this proves the fallback stays correct).

**Correction from the design doc's original "same-name shadowing between nested `let`s" case:** Elm 0.19.2 unconditionally rejects any local binding that reuses a name already bound in an ancestor lexical scope (a hard `SHADOWING` compiler error, not a warning — see `compiler/src/Reporting/Error/Canonicalize.hs`'s `Shadowing` constructor and <https://elm-lang.org/0.19.2/shadowing>). That scenario can never be expressed in valid Elm source, so it cannot be exercised by any scratch project; the case below replaces it with something that both compiles and has real verification value (see `docs/superpowers/specs/2026-07-03-local-arity-call-bypass-design.md`'s "Correction" note for the full explanation).

- [ ] **Step 1: Create the scratch project directory and `elm.json`**

```bash
mkdir -p /tmp/elm-local-arity/src /tmp/elm-local-arity/baseline
```

Write `/tmp/elm-local-arity/elm.json` (`elm/json` is required because the scratch module below is a `port module` — every port payload is encoded/decoded through it):

```json
{
    "type": "application",
    "source-directories": [
        "src"
    ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": {
            "elm/core": "1.0.5",
            "elm/json": "1.1.3"
        },
        "indirect": {}
    },
    "test-dependencies": {
        "direct": {},
        "indirect": {}
    }
}
```

- [ ] **Step 2: Write the scratch module**

Write `/tmp/elm-local-arity/src/Main.elm`:

```elm
port module Main exposing (main)


port output : String -> Cmd msg


-- Case A: plain local helper, called directly twice
validate : Int -> Int -> Int -> Bool
validate a b c =
    let
        check x y =
            x > 0 && y > 0
    in
    if check a b then
        check b c

    else
        False


-- Case B: TailDef loop, entry call from outside its own body
sumList : List Int -> Int
sumList list =
    let
        go acc xs =
            case xs of
                [] ->
                    acc

                x :: rest ->
                    go (acc + x) rest
    in
    go 0 list


-- Partial application of a local function: `inRange 0` supplies only 1 of
-- `inRange`'s 2 arguments, so this call site's `length args` (1) never
-- equals `inRange`'s arity (2). The direct-call bypass's guard
-- (`arity == length args`) must leave this alone -- it should compile
-- and behave exactly as it did before this change (a plain `inRange(0)`
-- call producing a curried 1-argument function, handed to List.filter).
partialApplication : List Int -> Int
partialApplication xs =
    let
        inRange lo x =
            x >= lo && x <= lo + 10
    in
    List.length (List.filter (inRange 0) xs)


-- Forward reference / mutual recursion between local let-peers.
-- `isEven`'s call to `isOdd` is a forward reference (isOdd's arity isn't
-- known yet when isEven's body is generated) and must keep using A2.
-- `isOdd`'s call to `isEven` is a backward reference (isEven's arity is
-- already known) and should get the direct-call bypass after this change.
isEvenViaMutual : Int -> Bool
isEvenViaMutual n =
    let
        isEven k =
            if k == 0 then
                True

            else
                isOdd (k - 1)

        isOdd k =
            if k == 0 then
                False

            else
                isEven (k - 1)
    in
    isEven n


boolToString : Bool -> String
boolToString b =
    if b then
        "True"

    else
        "False"


results : String
results =
    String.join ", "
        [ boolToString (validate 1 2 3)
        , String.fromInt (sumList (List.range 1 10))
        , String.fromInt (partialApplication (List.range (-5) 15))
        , boolToString (isEvenViaMutual 10)
        ]


main : Program () () msg
main =
    Platform.worker
        { init = \_ -> ( (), output results )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

- [ ] **Step 3: Build the compiler at the current (pre-change) commit**

Run from the repo root:

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds (exit code 0), no warnings.

- [ ] **Step 4: Compile the scratch module in both Dev and Prod mode**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v /tmp/elm-local-arity:/test -v elm-local-arity-home:/root/.elm \
  haskell:9.8.4 bash -c '
    export PATH=/opt/ghc/9.8.4/bin:$PATH
    BIN=$(cabal list-bin elm)
    cd /test
    $BIN make src/Main.elm --output=baseline/dev.js
    $BIN make src/Main.elm --optimize --output=baseline/prod.js
  '
```

Expected: both commands succeed and produce `/tmp/elm-local-arity/baseline/dev.js` and `/tmp/elm-local-arity/baseline/prod.js` (root-owned — that's expected for Docker-mounted output, per `CLAUDE.md`).

- [ ] **Step 5: Confirm the baseline uses `A2` for all four cases, and run it under Node**

```bash
grep -o 'A2(check' /tmp/elm-local-arity/baseline/prod.js | sort | uniq -c
grep -o 'A2(go' /tmp/elm-local-arity/baseline/prod.js
grep -o 'A2(isOdd\|A2(isEven' /tmp/elm-local-arity/baseline/prod.js
grep -c 'inRange(0)' /tmp/elm-local-arity/baseline/prod.js
```

Expected: the first three all appear as `A2(...)` — none should be `.f(...)` yet, since this is the pre-change compiler. The fourth (`inRange(0)`) is a plain call, count ≥ 1 — partial application never went through `A2` even before this change, since `List.length args (1) /= inRange's arity (2)`; this establishes the pre-change baseline for that shape too, so Task 4 can confirm it's *unchanged*, not newly accelerated.

```bash
node -e "
global.XMLHttpRequest = function () {};
require('/tmp/elm-local-arity/baseline/prod.js');
var app = this.Elm.Main.init();
app.ports.output.subscribe(function (msg) {
  console.log(msg);
  process.exit(0);
});
" | tee /tmp/elm-local-arity/baseline/node-output.txt
```

Expected output: `True, 55, 11, True` (`partialApplication`'s `List.range (-5) 15` yields `[-5..15]`; `inRange 0` keeps `0..10`, 11 values)

- [ ] **Step 6: Save a copy of the generated JS text for later diffing**

```bash
cp /tmp/elm-local-arity/baseline/dev.js /tmp/elm-local-arity/baseline/dev.saved.js
cp /tmp/elm-local-arity/baseline/prod.js /tmp/elm-local-arity/baseline/prod.saved.js
```

(No commit for this task — it's scratch state outside the repo, per `CLAUDE.md`'s guidance not to use a real repo-tracked project for manual `elm make` verification.)

---

### Task 2: Add local-arity tracking to `Generate.Mode`

**Files:**
- Modify: `compiler/src/Generate/Mode.hs`

**Interfaces:**
- Consumes: nothing new (extends the existing `Mode`/`Arities` types).
- Produces:
  - `Mode.addLocalArity :: Name.Name -> Int -> Mode -> Mode`
  - `Mode.lookupLocalArity :: Mode -> Name.Name -> Maybe Int`

- [ ] **Step 1: Export the two new functions**

In `compiler/src/Generate/Mode.hs`, change the export list:

```haskell
module Generate.Mode
  ( Mode(..)
  , isDebug
  , ShortFieldNames
  , shortenFieldNames
  , Arities
  , computeArities
  , lookupArity
  , lookupUnwrapped
  , lookupRawLocal
  , setRawLocal
  , lookupLocalArity
  , addLocalArity
  )
  where
```

- [ ] **Step 2: Add the `_localArities` field to `Arities` and update `computeArities`**

Replace:

```haskell
data Arities =
  Arities
    { _arities :: Map.Map Opt.Global Int
    , _unwrapped :: Map.Map Opt.Global (Int, Int)
    , _rawLocal :: Maybe (Name.Name, Int)
    }


computeArities :: Opt.GlobalGraph -> Arities
computeArities (Opt.GlobalGraph nodes _) =
  let arities = Map.mapMaybeWithKey (nodeArity nodes) nodes in
  Arities arities (computeUnwrapped nodes arities) Nothing
```

with:

```haskell
data Arities =
  Arities
    { _arities :: Map.Map Opt.Global Int
    , _unwrapped :: Map.Map Opt.Global (Int, Int)
    , _rawLocal :: Maybe (Name.Name, Int)
    , _localArities :: Map.Map Name.Name Int
    }


computeArities :: Opt.GlobalGraph -> Arities
computeArities (Opt.GlobalGraph nodes _) =
  let arities = Map.mapMaybeWithKey (nodeArity nodes) nodes in
  Arities arities (computeUnwrapped nodes arities) Nothing Map.empty
```

- [ ] **Step 3: Update the three existing functions that pattern-match on `Arities`**

Replace:

```haskell
lookupArity :: Mode -> Opt.Global -> Maybe Int
lookupArity mode global =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities arities _ _) -> Map.lookup global arities


-- Which globals have an `$unwrapped` sibling definition, which of their
-- parameters is the raw callback, and with how many arguments that
-- callback is always called. See UNWRAPPED HIGHER-ORDER FUNCTIONS below.
lookupUnwrapped :: Mode -> Opt.Global -> Maybe (Int, Int)
lookupUnwrapped mode global =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities _ unwrapped _) -> Map.lookup global unwrapped


-- While generating the body of an `$unwrapped` variant, the callback
-- parameter holds a raw JS function (of the given arity) instead of an
-- F2..F9-wrapped one. Call sites of that local must not go through A2..A9.
lookupRawLocal :: Mode -> Maybe (Name.Name, Int)
lookupRawLocal mode =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities _ _ raw) -> raw


setRawLocal :: Name.Name -> Int -> Mode -> Mode
setRawLocal name arity mode =
  case mode of
    Dev _ -> mode
    Prod fields (Arities arities unwrapped _) ->
      Prod fields (Arities arities unwrapped (Just (name, arity)))
```

with:

```haskell
lookupArity :: Mode -> Opt.Global -> Maybe Int
lookupArity mode global =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities arities _ _ _) -> Map.lookup global arities


-- Which globals have an `$unwrapped` sibling definition, which of their
-- parameters is the raw callback, and with how many arguments that
-- callback is always called. See UNWRAPPED HIGHER-ORDER FUNCTIONS below.
lookupUnwrapped :: Mode -> Opt.Global -> Maybe (Int, Int)
lookupUnwrapped mode global =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities _ unwrapped _ _) -> Map.lookup global unwrapped


-- While generating the body of an `$unwrapped` variant, the callback
-- parameter holds a raw JS function (of the given arity) instead of an
-- F2..F9-wrapped one. Call sites of that local must not go through A2..A9.
lookupRawLocal :: Mode -> Maybe (Name.Name, Int)
lookupRawLocal mode =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities _ _ raw _) -> raw


setRawLocal :: Name.Name -> Int -> Mode -> Mode
setRawLocal name arity mode =
  case mode of
    Dev _ -> mode
    Prod fields (Arities arities unwrapped _ locals) ->
      Prod fields (Arities arities unwrapped (Just (name, arity)) locals)


-- Look up the arity of a local let-bound named function currently in
-- scope (see `addLocalArity` and Generate.JavaScript.Expression's
-- handling of `Opt.Let`). Only arities in `restrictRange` are ever
-- present, since only those go through A2..A9 in the first place.
lookupLocalArity :: Mode -> Name.Name -> Maybe Int
lookupLocalArity mode name =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities _ _ _ locals) -> Map.lookup name locals


-- Record that a local let-bound function of the given arity is now in
-- scope, so direct calls to it (in its own body, for local recursion, and
-- in the following expression) can skip A2..A9 the same way known-arity
-- global calls do. Only arities 2..9 are tracked, since outside that
-- range there is no A-dispatch to bypass.
addLocalArity :: Name.Name -> Int -> Mode -> Mode
addLocalArity name arity mode =
  case mode of
    Dev _ -> mode
    Prod fields (Arities arities unwrapped raw locals) ->
      case restrictRange arity of
        Nothing -> mode
        Just n  -> Prod fields (Arities arities unwrapped raw (Map.insert name n locals))
```

- [ ] **Step 4: Build to confirm it type-checks**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds. `addLocalArity`/`lookupLocalArity` are unused at this point, but since they're in the module's export list, `-Wall` will not flag them as unused top-level bindings.

- [ ] **Step 5: Commit**

```bash
git add compiler/src/Generate/Mode.hs
git commit -m "$(cat <<'EOF'
perf: add local-arity tracking to Generate.Mode

Extends Arities with a map of locally in-scope, known-arity let-bound
functions, threaded the same way the existing raw-local mechanism is.
Not yet wired into codegen -- see the following task.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

This task's edit is only type-checked, not yet wired up or behavior-verified — that happens in Task 3 and Task 4. This commit exists for a clean per-task review diff; Task 4 squashes it together with Task 3's commit into the single `perf: ...` commit this optimization lands as (matching this repo's existing pattern of one commit per landed optimization, e.g. `be2c061f`, `2d47134d`).

---

### Task 3: Wire the bypass into `Generate.JavaScript.Expression`

**Files:**
- Modify: `compiler/src/Generate/JavaScript/Expression.hs`

**Interfaces:**
- Consumes: `Mode.addLocalArity`, `Mode.lookupLocalArity` (Task 2).
- Produces:
  - New case branch in `generate` for `Opt.Let` that extends `Mode` via a new helper `extendWithLocalArity`.
  - New function `extendWithLocalArity :: Mode.Mode -> Opt.Def -> Mode.Mode`.
  - New branch in `generateCall` for `Opt.VarLocal`.
  - New function `generateDirectLocalCall :: Mode.Mode -> Name.Name -> [Opt.Expr] -> JS.Expr`.

- [ ] **Step 1: Extend the `Opt.Let` case in `generate` to thread local arities**

In `compiler/src/Generate/JavaScript/Expression.hs`, replace:

```haskell
    Opt.Let def body ->
      JsBlock $
        generateDef mode def : codeToStmtList (generate mode body)
```

with:

```haskell
    Opt.Let def body ->
      let mode' = extendWithLocalArity mode def in
      JsBlock $
        generateDef mode' def : codeToStmtList (generate mode' body)
```

Note both `def` (so a local function can call itself directly outside a
tail position, e.g. a non-tail local recursive call) and `body` (the
following expression, i.e. `rest` in the design doc) are generated with
the extended mode.

- [ ] **Step 2: Add `extendWithLocalArity` near `generateDef`**

In `compiler/src/Generate/JavaScript/Expression.hs`, immediately above `generateDef` (around line 927), add:

```haskell
-- Record the arity of a local let-bound named function so that direct
-- calls to it (in its own body, for local recursion, and in the
-- following expression) can skip A2..A9. Deliberately v1-scoped:
-- destructured function values aren't covered (arity isn't syntactically
-- visible at the binding site), and this only grows the map top-down, so
-- a forward reference to a sibling defined *later* in the same let-chain
-- still falls back to A2..A9 -- correct, just not accelerated. See
-- docs/superpowers/specs/2026-07-03-local-arity-call-bypass-design.md.
extendWithLocalArity :: Mode.Mode -> Opt.Def -> Mode.Mode
extendWithLocalArity mode def =
  case def of
    Opt.Def name (Opt.Function args _) -> Mode.addLocalArity name (length args) mode
    Opt.Def _ _                        -> mode
    Opt.TailDef name args _            -> Mode.addLocalArity name (length args) mode
    Opt.TailDefCons name args _        -> Mode.addLocalArity name (length args) mode
```

- [ ] **Step 3: Add the `generateCall` branch and `generateDirectLocalCall`**

In `compiler/src/Generate/JavaScript/Expression.hs`, replace the `generateCall` function:

```haskell
generateCall :: Mode.Mode -> Opt.Expr -> [Opt.Expr] -> JS.Expr
generateCall mode func args =
  case func of
    Opt.VarGlobal global | Just unwrappedCall <- generateUnwrappedCall mode global args ->
      unwrappedCall

    -- inside an `$unwrapped` variant the callback parameter holds a raw
    -- JS function, so a saturated call of it must not go through A2..A9
    Opt.VarLocal x | Just (raw, arity) <- Mode.lookupRawLocal mode
                   , x == raw
                   , arity == length args ->
      JS.Call (JS.Ref (JsName.fromLocal x)) (map (generateJsExpr mode) args)

    Opt.VarGlobal global@(Opt.Global (ModuleName.Canonical pkg _) _) | pkg == Pkg.core ->
      generateCoreCall mode global args

    Opt.VarGlobal global | Just arity <- Mode.lookupArity mode global, arity == length args ->
      generateDirectCall mode global args

    Opt.VarBox _ ->
      case mode of
        Mode.Dev  _ -> generateCallHelp mode func args
        Mode.Prod _ _ ->
          case args of
            [arg] -> generateJsExpr mode arg
            _     -> generateCallHelp mode func args

    _ ->
      generateCallHelp mode func args
```

with:

```haskell
generateCall :: Mode.Mode -> Opt.Expr -> [Opt.Expr] -> JS.Expr
generateCall mode func args =
  case func of
    Opt.VarGlobal global | Just unwrappedCall <- generateUnwrappedCall mode global args ->
      unwrappedCall

    -- inside an `$unwrapped` variant the callback parameter holds a raw
    -- JS function, so a saturated call of it must not go through A2..A9
    Opt.VarLocal x | Just (raw, arity) <- Mode.lookupRawLocal mode
                   , x == raw
                   , arity == length args ->
      JS.Call (JS.Ref (JsName.fromLocal x)) (map (generateJsExpr mode) args)

    -- a call to a local let-bound function whose arity is known from its
    -- own binding (see Opt.Let handling / extendWithLocalArity): skip
    -- A2..A9 and call its raw `.f` field directly, the same way
    -- generateDirectCall does for globals.
    Opt.VarLocal x | Just arity <- Mode.lookupLocalArity mode x, arity == length args ->
      generateDirectLocalCall mode x args

    Opt.VarGlobal global@(Opt.Global (ModuleName.Canonical pkg _) _) | pkg == Pkg.core ->
      generateCoreCall mode global args

    Opt.VarGlobal global | Just arity <- Mode.lookupArity mode global, arity == length args ->
      generateDirectCall mode global args

    Opt.VarBox _ ->
      case mode of
        Mode.Dev  _ -> generateCallHelp mode func args
        Mode.Prod _ _ ->
          case args of
            [arg] -> generateJsExpr mode arg
            _     -> generateCallHelp mode func args

    _ ->
      generateCallHelp mode func args
```

Then, immediately after `generateDirectCall` (which sits just above `rawFunctionField`), add:

```haskell
-- Same idea as generateDirectCall, but for a local let-bound function
-- instead of a global.
generateDirectLocalCall :: Mode.Mode -> Name.Name -> [Opt.Expr] -> JS.Expr
generateDirectLocalCall mode name args =
  JS.Call
    (JS.Access (JS.Ref (JsName.fromLocal name)) rawFunctionField)
    (map (generateJsExpr mode) args)
```

- [ ] **Step 4: Build to confirm it type-checks**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds, no warnings.

- [ ] **Step 5: Commit**

```bash
git add compiler/src/Generate/JavaScript/Expression.hs
git commit -m "$(cat <<'EOF'
perf: wire local-arity direct-call bypass into codegen

Opt.Let now threads the extended local-arity Mode into both the def's
own body and the following expression; generateCall gains a matching
Opt.VarLocal branch. End-to-end behavior is verified in the next task.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

End-to-end behavior verification against the Task 1 baseline happens in Task 4, which squashes this commit together with Task 2's into the single `perf: ...` commit this optimization lands as.

---

### Task 4: Verify against baseline and commit

**Files:**
- None modified (verification only), except the final commit of Tasks 2 & 3's changes.

**Interfaces:**
- Consumes: the baseline outputs from Task 1 (`/tmp/elm-local-arity/baseline/*`), and the `elm` binary built from Tasks 2+3's changes.

- [ ] **Step 1: Recompile the same scratch module with the changed compiler**

```bash
mkdir -p /tmp/elm-local-arity/after
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v /tmp/elm-local-arity:/test -v elm-local-arity-home:/root/.elm \
  haskell:9.8.4 bash -c '
    export PATH=/opt/ghc/9.8.4/bin:$PATH
    BIN=$(cabal list-bin elm)
    cd /test
    $BIN make src/Main.elm --output=after/dev.js
    $BIN make src/Main.elm --optimize --output=after/prod.js
  '
```

Expected: both commands succeed.

- [ ] **Step 2: Confirm Dev-mode output is byte-identical (the hard invariant)**

```bash
diff /tmp/elm-local-arity/baseline/dev.saved.js /tmp/elm-local-arity/after/dev.js
```

Expected: no output (files identical). If this diff is non-empty, stop — the `Mode.Prod`-only invariant has been violated and the change in Task 2/3 needs to be reviewed (most likely `Dev` is somehow reaching `addLocalArity`/`lookupLocalArity` with non-`Nothing` results, which should be structurally impossible given both are `case mode of Dev _ -> ...` no-ops).

- [ ] **Step 3: Confirm Prod-mode output changed exactly as expected**

```bash
diff /tmp/elm-local-arity/baseline/prod.saved.js /tmp/elm-local-arity/after/prod.js
```

Expected: a non-empty diff. Specifically:
- The two `check(...)` calls in `validate` (Case A) change from `A2(check, ...)` to `check.f(...)`.
- The `go(...)` entry call in `sumList` (Case B) changes from `A2(go, 0, list)` to `go.f(0, list)`.
- In `partialApplication`, `inRange(0)` stays exactly as it was — untouched, since that call site is undersaturated (1 arg against `inRange`'s arity of 2) and never went through `A2` in the first place. Confirm no change here explicitly:

  ```bash
  diff <(grep -o 'inRange(0)' /tmp/elm-local-arity/baseline/prod.saved.js) <(grep -o 'inRange(0)' /tmp/elm-local-arity/after/prod.js)
  ```

  Expected: no output (identical).
- In `isEvenViaMutual`, the `Let` chain generates in written order (`isEven`'s `Let` wraps `isOdd`'s `Let` wraps the final `isEven n` call), so:
  - `isEven`'s call to `isOdd` is a **forward** reference (`isOdd`'s arity isn't recorded yet when `isEven`'s body is generated) — stays `A2(isOdd, ...)`.
  - `isOdd`'s call to `isEven` is a **backward** reference (`isEven`'s arity was already recorded) — becomes `isEven.f(...)`.
  - The final entry call `isEven n` is also backward (both are known by then) — becomes `isEven.f(...)`.

Confirm this explicitly:

```bash
grep -c 'A2(isOdd' /tmp/elm-local-arity/after/prod.js
grep -c 'A2(isEven' /tmp/elm-local-arity/after/prod.js
grep -c 'isEven\.f(' /tmp/elm-local-arity/after/prod.js
grep -c 'isOdd\.f(' /tmp/elm-local-arity/after/prod.js
```

Expected: `A2(isOdd` count ≥ 1 (the not-yet-accelerated forward reference), `A2(isEven` count 0 (no remaining A2 calls to `isEven`), `isEven.f(` count ≥ 2 (isOdd's call plus the final entry call, both accelerated), `isOdd.f(` count 0 (nothing ever calls `isOdd` after its arity is known, so it never gets the direct-call rewrite).

- [ ] **Step 4: Run the new Prod output under Node and confirm behavior is unchanged**

```bash
node -e "
global.XMLHttpRequest = function () {};
require('/tmp/elm-local-arity/after/prod.js');
var app = this.Elm.Main.init();
app.ports.output.subscribe(function (msg) {
  console.log(msg);
  process.exit(0);
});
"
```

Expected output: `True, 55, 11, True` (`partialApplication`'s `List.range (-5) 15` yields `[-5..15]`; `inRange 0` keeps `0..10`, 11 values) — identical to the baseline run in Task 1, Step 5.

- [ ] **Step 5: Squash Task 2 and Task 3's commits into the single landed commit**

Tasks 2 and 3 each committed separately (for clean per-task review diffs). Now that end-to-end behavior is verified, squash them into the one commit this optimization lands as — reset back to before Task 2's commit, keeping the changes staged, then make a single commit:

```bash
git reset --soft HEAD~2
git commit -m "$(cat <<'EOF'
perf: direct-call bypass for local let-bound functions

Extends the known-arity A2..A9 bypass (previously globals only) to local
let-bound named functions: a call to a local function whose arity is
known from its own binding skips the generic arity-dispatch helpers and
calls .f directly, the same way known-arity global calls already do.

v1 is deliberately scoped to sequential (top-down) visibility within a
let-chain -- forward references and mutual recursion between local
let-peers still fall back to A2..A9, correctly, just not accelerated.
See docs/superpowers/specs/2026-07-03-local-arity-call-bypass-design.md.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 6 (optional): Rough before/after benchmark**

Not required to land this change, but useful for the memory record (in the
spirit of the `1.3x sortWith` figure noted for the compare/min/max work).
Add a hot local helper to the scratch module and time it, e.g. append to
`src/Main.elm` before `main`:

```elm
benchmarkResult : Int
benchmarkResult =
    let
        isPrime n =
            if n < 2 then
                False

            else
                isPrimeHelp n 2

        isPrimeHelp n d =
            if d * d > n then
                True

            else if modBy d n == 0 then
                False

            else
                isPrimeHelp n (d + 1)
    in
    List.length (List.filter isPrime (List.range 2 200000))
```

Wire it into `results` temporarily, rebuild `baseline/prod.js` (pre-change
commit) and `after/prod.js` (post-change), and time each with:

```bash
node -e "
global.XMLHttpRequest = function () {};
var start = Date.now();
require('/tmp/elm-local-arity/after/prod.js');
console.log(Date.now() - start, 'ms load+eval');
"
```

for a rough load+eval comparison, or wrap the relevant computation in a
`Time.now`-based measurement exposed through the `output` port for an
in-VM timing. Record any notable delta in the fork's memory file for this
optimization (see `[[trmc-plan]]`-style entries in `MEMORY.md`).

- [ ] **Step 7: Clean up scratch state**

```bash
rm -rf /tmp/elm-local-arity
docker volume rm elm-local-arity-home
```
