# Tuple Closed-Shape Compare Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `<`/`<=`/`>`/`>=`/`compare`/`min`/`max` on a closed (proven, non-generic) Tuple2/Tuple3 —
recursively of comparable scalars (Int/Float/String/Char) or nested closed tuples — compile in
`--optimize` builds to fully unrolled, short-circuiting inline comparisons instead of a call into the
generic kernel `_Utils_cmp` (and, for `compare`/`min`/`max`, instead of a real `F2`/`A2` dispatch on top
of that).

**Architecture:** Extends the existing `CProbe`/`Type.Solve` pipeline (the same one `Type.toPrimType`/
`_primHints` and `EqClosed` already use) with one more resolution pass, feeding two new opaque
`AST.Optimized` nodes: `CmpOpClosed` (for the four operators, Bool-valued) and `CmpCallClosed` (for
`compare`/`min`/`max`, Order- or operand-valued). Each node's own `Generate.JavaScript.Expression` codegen
function is the *only* place Dev/Prod ever diverge — Dev reproduces today's exact codegen byte-for-byte by
calling the same helpers (`cmp`, `generateGlobalCall`) the generic path already uses; Prod lowers the
shape into fully inlined JS. Full design rationale, the two corrections found while drafting this plan
(baseline modeling error; Dev-byte-identity incompatibility of the originally-proposed single-ordinal-node
design), and file list: `docs/superpowers/specs/2026-07-23-tuple-compare-closed-shape-design.md` — read it
before starting; this plan assumes its scope decisions without re-litigating them.

**Tech Stack:** Haskell (GHC 9.8.4 via the `haskell:9.8.4` Docker image), `cabal build`, no local
toolchain — see `CLAUDE.md`'s Build section for the exact Docker invocation. No automated test suite
exists in this repo; verification is manual (build + scratch Elm project + JS inspection/execution), per
`CLAUDE.md`'s Testing section.

## Global Constraints

- `-Wall -Werror` is baked into `elm.cabal` — any warning (unused binds, incomplete patterns, unused
  imports) fails the build. Every task's "build" step must produce a clean, warning-free build.
- Every task that changes `AST.Optimized`'s `Expr` type is a wire-format change: after Task 3, any
  previously-built `.elmo`/`.elmi` cache (project `elm-stuff/`, `ELM_HOME` package cache) becomes
  unreadable ("Corrupt File") until deleted. Use a **fresh** `ELM_HOME` volume for any scratch-project
  compile from Task 3 onward.
- Dev-mode (`elm make` without `--optimize`) JS output must be **byte-identical** before and after this
  entire plan, for every program — this is verified explicitly in Task 5, and is the sharpest test of
  whether the two new nodes' Dev-mode codegen paths were implemented correctly (see the design spec's
  "Corrections" section for why this is easy to get subtly wrong here).
- Char must **never** be added to the shared `Type.PrimType` (see Task 1 — it feeds Dev+Prod-uniform
  scalar codegen elsewhere, and Char is boxed in `--debug` builds). This plan's Char support goes through
  a separate, standalone probe (`isCmpLeafType`) instead.
- Follow `CLAUDE.md`'s Docker build recipe verbatim for every "run the build" step in this plan; don't
  invent a different invocation.

---

### Task 1: Closed-tuple-compare probes in `Type.Type`

**Files:**
- Modify: `compiler/src/Type/Type.hs`

**Interfaces:**
- Consumes: `Variable`, `Descriptor(..)`, `Content(..)`, `FlatType(..)` (`Tuple1`, `App1`) — all existing,
  same file.
- Produces (used by Task 2): `toClosedCmpShape :: Variable -> IO (Maybe CmpShape)` and the `CmpShape`
  type it returns (`CmpLeaf | CmpTuple2 CmpShape CmpShape | CmpTuple3 CmpShape CmpShape CmpShape`,
  `deriving (Eq)`).

- [ ] **Step 1: Add `CmpShape(..)` and `toClosedCmpShape` to the export list**

In `compiler/src/Type/Type.hs`, the module export list currently has (around line 11-15):

```haskell
  , PrimType(..)
  , toPrimType
  , toClosedFields
  , toClosedPrimFields
  , toClosedUnionEqArity
  , noRank
```

Change it to:

```haskell
  , PrimType(..)
  , toPrimType
  , toClosedFields
  , toClosedPrimFields
  , toClosedUnionEqArity
  , CmpShape(..)
  , toClosedCmpShape
  , noRank
```

- [ ] **Step 2: Add `CmpShape`, `toClosedCmpShape`, `toClosedCmpSlot`, `isCmpLeafType`**

Find `closedPrimOfCanType`'s definition (ends right before the `-- WEBGL TYPES` comment, around line
412-414):

```haskell
    Can.TAlias _ _ [] (Can.Holey realType) ->
      closedPrimOfCanType realType

    _ ->
      Nothing


-- WEBGL TYPES
```

Insert the following between `closedPrimOfCanType`'s closing `Nothing` case and the `-- WEBGL TYPES`
comment:

```haskell
    Can.TAlias _ _ [] (Can.Holey realType) ->
      closedPrimOfCanType realType

    _ ->
      Nothing


-- CLOSED TUPLE COMPARE PROBES
--
-- Determines whether a resolved Variable is a Tuple2/Tuple3 whose every
-- slot is either a comparable scalar (Int/Float/String/Char) or itself a
-- closed-cmp Tuple2/Tuple3 (recursive -- covers tuples of tuples).
-- Deliberately does NOT reuse PrimType/toPrimType for the scalar check
-- (see isCmpLeafType below) and deliberately does not attempt List (no
-- static arity to unroll) or Record/Union slots (a tuple-only first pass
-- -- see Generate.JavaScript.Expression's generateCmpOpClosed/
-- generateCmpCallClosed, the only consumers of this shape, both
-- Prod-mode-only).


data CmpShape
  = CmpLeaf
  | CmpTuple2 CmpShape CmpShape
  | CmpTuple3 CmpShape CmpShape CmpShape
  deriving (Eq)


toClosedCmpShape :: Variable -> IO (Maybe CmpShape)
toClosedCmpShape variable =
  do  (Descriptor content _ _ _) <- UF.get variable
      case content of
        Structure (Tuple1 a b Nothing) ->
          do  maybeA <- toClosedCmpSlot a
              maybeB <- toClosedCmpSlot b
              return (CmpTuple2 <$> maybeA <*> maybeB)

        Structure (Tuple1 a b (Just c)) ->
          do  maybeA <- toClosedCmpSlot a
              maybeB <- toClosedCmpSlot b
              maybeC <- toClosedCmpSlot c
              return (CmpTuple3 <$> maybeA <*> maybeB <*> maybeC)

        Alias _ _ _ realVariable ->
          toClosedCmpShape realVariable

        _ ->
          return Nothing


toClosedCmpSlot :: Variable -> IO (Maybe CmpShape)
toClosedCmpSlot variable =
  do  isLeaf <- isCmpLeafType variable
      if isLeaf then
        return (Just CmpLeaf)
      else
        toClosedCmpShape variable


-- Recognizes Int/Float/String/Char -- the "comparable" scalar leaf types
-- -- WITHOUT reusing PrimType/toPrimType. This is deliberate: toPrimType
-- feeds toPrimBinop's raw `===`/`<` scalar codegen (Opt.PrimOp), which is
-- NOT Mode-gated (Generate.JavaScript.Expression's generatePrimOp has no
-- Mode.Dev/Mode.Prod split at all) and therefore applies in Dev/--debug
-- builds too, where Char is boxed (_Utils_chr__DEBUG wraps it in
-- `new String(c)`), making a raw `===` WRONG (`new String('a') === new
-- String('a')` is false). This closed-cmp feature's own codegen
-- (Generate.JavaScript.Expression's generateCmpOpClosed/
-- generateCmpCallClosed) is Prod-mode-only -- Dev mode always falls back
-- to the untouched existing codegen -- so Char is safe here in a way it
-- would not be if merged into the shared PrimType.
isCmpLeafType :: Variable -> IO Bool
isCmpLeafType variable =
  do  (Descriptor content _ _ _) <- UF.get variable
      case content of
        Structure (App1 home name []) ->
          return $
            (home == ModuleName.basics && name == "Int")
            || (home == ModuleName.basics && name == "Float")
            || (home == ModuleName.string && name == "String")
            || (home == ModuleName.char && name == "Char")

        Alias _ _ _ realVariable ->
          isCmpLeafType realVariable

        _ ->
          return False


-- WEBGL TYPES
```

(`ModuleName.char`/`ModuleName.string` are already imported and used elsewhere in this file — no new
imports needed.)

- [ ] **Step 3: Build and verify no warnings**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds, no warnings. `toClosedCmpShape` is unused at this point but exported, so GHC
does not warn.

- [ ] **Step 4: Commit**

```bash
git add compiler/src/Type/Type.hs
git commit -m "feat: add closed-tuple-compare probes to Type.Type"
```

---

### Task 2: Thread the new hint map through `Type.Solve`, `Compile`, and `Optimize.Module`

**Files:**
- Modify: `compiler/src/Type/Solve.hs`
- Modify: `compiler/src/Compile.hs`
- Modify: `compiler/src/Optimize/Module.hs`
- Modify: `compiler/src/Optimize/Expression.hs` (only the `Hints` record — no behavior change yet)

**Interfaces:**
- Consumes: `Type.toClosedCmpShape`, `Type.CmpShape` from Task 1.
- Produces (used by Task 4): `Optimize.Expression.Hints` gains `_cmpHints :: Map.Map A.Region
  Opt.CmpShape`, fully populated end-to-end from `Compile.compile`. Nothing reads this field yet (Task 4
  does) — this task is pure plumbing.

- [ ] **Step 1: Extend `Type.Solve`'s `run` signature and body**

In `compiler/src/Type/Solve.hs`, replace the existing `run` (around line 34-51):

```haskell
run :: ModuleName.Canonical -> Map.Map Name.Name Can.Union -> Constraint -> IO (Either (NE.List Error.Error) (Map.Map Name.Name Can.Annotation, Map.Map A.Region Type.PrimType, Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region Int))
run home unions constraint =
  do  pools <- MVector.replicate 8 []

      (State env _ errors probes recordProbes) <-
        solve Map.empty outermostRank pools emptyState constraint

      case errors of
        [] ->
          do  annotations <- traverse Type.toAnnotation env
              hints <- resolveProbes probes
              shapeHints <- resolveRecordProbes recordProbes
              recordEqHints <- resolveRecordEqProbes probes
              unionEqHints <- resolveUnionEqProbes home unions probes
              return $ Right (annotations, hints, shapeHints, recordEqHints, unionEqHints)

        e:es ->
          return $ Left (NE.List e es)
```

with:

```haskell
run :: ModuleName.Canonical -> Map.Map Name.Name Can.Union -> Constraint -> IO (Either (NE.List Error.Error) (Map.Map Name.Name Can.Annotation, Map.Map A.Region Type.PrimType, Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region Int, Map.Map A.Region Type.CmpShape))
run home unions constraint =
  do  pools <- MVector.replicate 8 []

      (State env _ errors probes recordProbes) <-
        solve Map.empty outermostRank pools emptyState constraint

      case errors of
        [] ->
          do  annotations <- traverse Type.toAnnotation env
              hints <- resolveProbes probes
              shapeHints <- resolveRecordProbes recordProbes
              recordEqHints <- resolveRecordEqProbes probes
              unionEqHints <- resolveUnionEqProbes home unions probes
              cmpHints <- resolveCmpProbes probes
              return $ Right (annotations, hints, shapeHints, recordEqHints, unionEqHints, cmpHints)

        e:es ->
          return $ Left (NE.List e es)
```

- [ ] **Step 2: Add the new resolve-probe pass**

Right after `addUnionEqProbe`'s definition (end of the `-- CLOSED UNION EQUALITY HINTS` section, before
`-- SOLVER`), insert:

```haskell


-- CLOSED TUPLE COMPARE HINTS


resolveCmpProbes :: [(A.Region, Variable, Variable)] -> IO (Map.Map A.Region Type.CmpShape)
resolveCmpProbes probes =
  foldM addCmpProbe Map.empty probes


addCmpProbe :: Map.Map A.Region Type.CmpShape -> (A.Region, Variable, Variable) -> IO (Map.Map A.Region Type.CmpShape)
addCmpProbe hints (region, leftVar, rightVar) =
  do  maybeLeft <- Type.toClosedCmpShape leftVar
      maybeRight <- Type.toClosedCmpShape rightVar
      return $ case (maybeLeft, maybeRight) of
        (Just left, Just right) | left == right -> Map.insert region left hints
        _                                       -> hints
```

- [ ] **Step 3: Thread the new map through `Compile.hs`**

Replace `typeCheck`:

```haskell
typeCheck :: Src.Module -> Can.Module -> Either E.Error (Map.Map Name.Name Can.Annotation, Map.Map A.Region Type.PrimType, Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region Int)
typeCheck modul canonical =
  case unsafePerformIO (Type.run (Can._name canonical) (Can._unions canonical) =<< Type.constrain canonical) of
    Right result ->
      Right result

    Left errors ->
      Left (E.BadTypes (Localizer.fromModule modul) errors)
```

with:

```haskell
typeCheck :: Src.Module -> Can.Module -> Either E.Error (Map.Map Name.Name Can.Annotation, Map.Map A.Region Type.PrimType, Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region Int, Map.Map A.Region Type.CmpShape)
typeCheck modul canonical =
  case unsafePerformIO (Type.run (Can._name canonical) (Can._unions canonical) =<< Type.constrain canonical) of
    Right result ->
      Right result

    Left errors ->
      Left (E.BadTypes (Localizer.fromModule modul) errors)
```

Replace `compile`:

```haskell
compile :: Pkg.Name -> Map.Map ModuleName.Raw I.Interface -> Src.Module -> Either E.Error Artifacts
compile pkg ifaces modul =
  do  canonical <- canonicalize pkg ifaces modul
      (annotations, hints, shapeHints, recordEqHints, unionEqHints) <- typeCheck modul canonical
      ()        <- nitpick ifaces annotations canonical
      objects   <- optimize modul annotations hints shapeHints recordEqHints unionEqHints canonical
      return (Artifacts canonical annotations objects)
```

with:

```haskell
compile :: Pkg.Name -> Map.Map ModuleName.Raw I.Interface -> Src.Module -> Either E.Error Artifacts
compile pkg ifaces modul =
  do  canonical <- canonicalize pkg ifaces modul
      (annotations, hints, shapeHints, recordEqHints, unionEqHints, cmpHints) <- typeCheck modul canonical
      ()        <- nitpick ifaces annotations canonical
      objects   <- optimize modul annotations hints shapeHints recordEqHints unionEqHints cmpHints canonical
      return (Artifacts canonical annotations objects)
```

Replace `optimize`:

```haskell
optimize :: Src.Module -> Map.Map Name.Name Can.Annotation -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region Int -> Can.Module -> Either E.Error Opt.LocalGraph
optimize modul annotations hints shapeHints recordEqHints unionEqHints canonical =
  case snd $ R.run $ Optimize.optimize annotations hints shapeHints recordEqHints unionEqHints canonical of
    Right localGraph ->
      Right localGraph

    Left errors ->
      Left (E.BadMains (Localizer.fromModule modul) errors)
```

with:

```haskell
optimize :: Src.Module -> Map.Map Name.Name Can.Annotation -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region Int -> Map.Map A.Region Type.CmpShape -> Can.Module -> Either E.Error Opt.LocalGraph
optimize modul annotations hints shapeHints recordEqHints unionEqHints cmpHints canonical =
  case snd $ R.run $ Optimize.optimize annotations hints shapeHints recordEqHints unionEqHints cmpHints canonical of
    Right localGraph ->
      Right localGraph

    Left errors ->
      Left (E.BadMains (Localizer.fromModule modul) errors)
```

(`Compile.hs` already imports `qualified Type.Type as Type`, `qualified AST.Optimized as Opt`, etc. — no
import changes needed in this file.)

- [ ] **Step 4: Extend `Optimize.Expression`'s `Hints` record**

In `compiler/src/Optimize/Expression.hs`, replace the `Hints` doc comment + definition:

```haskell
-- _recordEqHints/_unionEqHints are analogous tables for `==`/`/=` sites on
-- a closed Record or closed same-module non-generic Normal-ctor Union type
-- whose fields/ctor-args are all JS-primitive-safe -- populated by
-- Type.Solve from the same CProbe constraints as _primHints (see
-- Type.Type's toClosedPrimFields/toClosedUnionEqArity). An absent entry in
-- both keeps the generic Basics.eq/neq call (-> _Utils_eq). See
-- AST.Optimized's EqClosed.
data Hints =
  Hints
    { _primHints :: Map.Map A.Region Type.PrimType
    , _recordShapeHints :: Map.Map A.Region (Set.Set Name.Name)
    , _recordEqHints :: Map.Map A.Region (Set.Set Name.Name)
    , _unionEqHints :: Map.Map A.Region Int
    }
```

with:

```haskell
-- _recordEqHints/_unionEqHints are analogous tables for `==`/`/=` sites on
-- a closed Record or closed same-module non-generic Normal-ctor Union type
-- whose fields/ctor-args are all JS-primitive-safe -- populated by
-- Type.Solve from the same CProbe constraints as _primHints (see
-- Type.Type's toClosedPrimFields/toClosedUnionEqArity). An absent entry in
-- both keeps the generic Basics.eq/neq call (-> _Utils_eq). See
-- AST.Optimized's EqClosed.
--
-- _cmpHints is the analogous table for `<`/`<=`/`>`/`>=`/`compare`/`min`/
-- `max` sites on a closed Tuple2/Tuple3-of-comparable-scalars shape --
-- populated by Type.Solve from the same CProbe constraints, converted from
-- Type.CmpShape to Opt.CmpShape once in Optimize.Module (see
-- Type.Type's toClosedCmpShape). An absent entry keeps the generic
-- Basics.lt/le/gt/ge/compare/min/max call. See AST.Optimized's
-- CmpOpClosed/CmpCallClosed.
data Hints =
  Hints
    { _primHints :: Map.Map A.Region Type.PrimType
    , _recordShapeHints :: Map.Map A.Region (Set.Set Name.Name)
    , _recordEqHints :: Map.Map A.Region (Set.Set Name.Name)
    , _unionEqHints :: Map.Map A.Region Int
    , _cmpHints :: Map.Map A.Region Opt.CmpShape
    }
```

- [ ] **Step 5: Wire the new field into `Optimize.Module`'s `Hints` construction, with the Type→Opt shape conversion**

In `compiler/src/Optimize/Module.hs`, replace:

```haskell
optimize :: Annotations -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region Int -> Can.Module -> Result i [W.Warning] Opt.LocalGraph
optimize annotations primHints shapeHints recordEqHints unionEqHints (Can.Module home _ _ decls unions aliases _ effects) =
  let hints = Expr.Hints primHints shapeHints recordEqHints unionEqHints in
```

with:

```haskell
optimize :: Annotations -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region Int -> Map.Map A.Region Type.CmpShape -> Can.Module -> Result i [W.Warning] Opt.LocalGraph
optimize annotations primHints shapeHints recordEqHints unionEqHints cmpHints (Can.Module home _ _ decls unions aliases _ effects) =
  let hints = Expr.Hints primHints shapeHints recordEqHints unionEqHints (Map.map toOptCmpShape cmpHints) in
```

Then, right after this `optimize` function's `where`-free body ends (i.e. right before the `-- UNION`
section comment that currently follows it), insert:

```haskell


-- Type.CmpShape (built from Variable-based unification data in
-- Type.Solve) and Opt.CmpShape (stored in the Opt AST / .elmo) are
-- deliberately separate types -- AST.Optimized never imports Type.Type,
-- matching how ClosedEqShape was kept self-contained rather than reusing
-- anything from the type-checker's internal modules. This is the one
-- place they meet.
toOptCmpShape :: Type.CmpShape -> Opt.CmpShape
toOptCmpShape shape =
  case shape of
    Type.CmpLeaf         -> Opt.CmpLeaf
    Type.CmpTuple2 a b   -> Opt.CmpTuple2 (toOptCmpShape a) (toOptCmpShape b)
    Type.CmpTuple3 a b c -> Opt.CmpTuple3 (toOptCmpShape a) (toOptCmpShape b) (toOptCmpShape c)
```

(`Optimize.Module.hs` already imports `qualified Type.Type as Type` and `qualified AST.Optimized as Opt`
— no import changes needed. `Opt.CmpShape`'s constructors don't exist yet — that's Task 3; this file
won't compile until Task 3 lands. That's fine, this whole plan's tasks are meant to be applied and built
in order.)

- [ ] **Step 6: Build and verify no warnings**

This step will **fail to build** until Task 3 adds `Opt.CmpShape`. Skip building at the end of this task;
Task 3's own build step will be the first point everything compiles again. (Contrast with the EqClosed
plan's Task 2, which *could* build standalone — that plan's hint types were all pre-existing `Set`/`Int`.
Here, `Opt.CmpShape` is itself new, so Tasks 2 and 3 are build-coupled. Commit anyway — see Step 7 — since
each commit should still represent one coherent, reviewable change; just note in the commit message that
the tree doesn't build until the next commit.)

- [ ] **Step 7: Commit**

```bash
git add compiler/src/Type/Solve.hs compiler/src/Compile.hs compiler/src/Optimize/Module.hs compiler/src/Optimize/Expression.hs
git commit -m "feat: thread closed-tuple-compare hints through Type.Solve and Compile

Does not build standalone -- Opt.CmpShape is introduced in the next commit."
```

---

### Task 3: New `CmpOpClosed`/`CmpCallClosed` Opt nodes, Binary encoding, and full Prod/Dev codegen

**Files:**
- Modify: `compiler/src/AST/Optimized.hs`
- Modify: `compiler/src/Nitpick/Debug.hs`
- Modify: `compiler/src/Generate/Mode.hs`
- Modify: `compiler/src/Nitpick/WorkerRegistry.hs`
- Modify: `compiler/src/Generate/JavaScript/Expression.hs`

**Interfaces:**
- Consumes: nothing constructed yet from earlier tasks (Task 2's `Optimize.Module.toOptCmpShape` produces
  values of the `Opt.CmpShape` type this task defines, closing the loop Task 2 left dangling).
- Produces (used by Task 4): `AST.Optimized.CmpOpClosed :: CmpOp -> CmpShape -> Expr -> Expr -> Expr`,
  `AST.Optimized.CmpCallClosed :: CmpShape -> Expr -> Expr -> CmpCallKind -> Expr`, and the `CmpOp`
  (`OpLt|OpLe|OpGt|OpGe`), `CmpCallKind` (`KCompare Expr Expr Expr|KMin|KMax`), `CmpShape`
  (`CmpLeaf|CmpTuple2 CmpShape CmpShape|CmpTuple3 CmpShape CmpShape CmpShape`) types it consumes.

This task must land as one atomic change, same reasoning as the EqClosed plan's Task 3: two new `Expr`
constructors mean every exhaustive `case` over `Opt.Expr` in this codebase (`-Wall`'s incomplete-patterns
check is `-Werror`) needs a matching arm in the same commit, so the real codegen is written now, not
stubbed.

- [ ] **Step 1: Add `CmpShape(..)`, `CmpOp(..)`, `CmpCallKind(..)` to the export list**

In `compiler/src/AST/Optimized.hs`, the export list currently starts:

```haskell
module AST.Optimized
  ( Def(..)
  , Expr(..)
  , PrimBinop(..)
  , ClosedEqShape(..)
  , Global(..)
```

Change it to:

```haskell
module AST.Optimized
  ( Def(..)
  , Expr(..)
  , PrimBinop(..)
  , ClosedEqShape(..)
  , CmpShape(..)
  , CmpOp(..)
  , CmpCallKind(..)
  , Global(..)
```

- [ ] **Step 2: Add the two new `Expr` constructors**

Find the end of the `data Expr` block (the `EqClosed` constructor is currently last):

```haskell
  -- Prod-mode-only codegen; Dev mode ignores the shape and keeps
  -- generating the ordinary _Utils_eq/_Utils_neq kernel call (Dev output
  -- must stay byte-identical -- see CLAUDE.md).
  | EqClosed Bool ClosedEqShape Expr Expr
```

Change it to:

```haskell
  -- Prod-mode-only codegen; Dev mode ignores the shape and keeps
  -- generating the ordinary _Utils_eq/_Utils_neq kernel call (Dev output
  -- must stay byte-identical -- see CLAUDE.md).
  | EqClosed Bool ClosedEqShape Expr Expr
  -- Emitted for `<`/`<=`/`>`/`>=` on a closed Tuple2/Tuple3-of-
  -- comparable-scalars shape (see Type.Type's toClosedCmpShape and
  -- Optimize.Expression's toClosedCmpTarget). Lets Generate.JavaScript
  -- skip the generic _Utils_cmp recursive walk in favor of a fully
  -- unrolled short-circuit boolean chain -- see
  -- Generate.JavaScript.Expression's generateCmpOpClosed. Prod-mode-only
  -- codegen; Dev mode reproduces the exact prior codegen (CLAUDE.md's
  -- Mode.Dev contract) by calling the same `cmp` helper the generic path
  -- already uses.
  | CmpOpClosed CmpOp CmpShape Expr Expr
  -- Emitted for closed-tuple `compare`/`min`/`max` (see CmpCallKind).
  -- Same Dev/Prod split as CmpOpClosed -- see
  -- Generate.JavaScript.Expression's generateCmpCallClosed.
  | CmpCallClosed CmpShape Expr Expr CmpCallKind
```

- [ ] **Step 3: Add the `CmpShape`, `CmpOp`, `CmpCallKind` types**

Find `ClosedEqShape`'s definition:

```haskell
data ClosedEqShape
  = ClosedEqRecord (Set.Set Name)
  | ClosedEqUnion Int
  deriving (Eq)
```

Insert right after it:

```haskell
data ClosedEqShape
  = ClosedEqRecord (Set.Set Name)
  | ClosedEqUnion Int
  deriving (Eq)


-- A closed Tuple2/Tuple3 shape whose leaves are all proven comparable
-- scalars (Int/Float/String/Char -- see Type.Type's isCmpLeafType).
-- Recursion covers nested tuples-of-tuples. Mirrors Type.CmpShape
-- structurally but is a separate type -- see Optimize.Module's
-- toOptCmpShape.
data CmpShape
  = CmpLeaf
  | CmpTuple2 CmpShape CmpShape
  | CmpTuple3 CmpShape CmpShape CmpShape


data CmpOp
  = OpLt
  | OpLe
  | OpGt
  | OpGe


-- Which Basics function CmpCallClosed stands in for. KCompare carries the
-- already-registered LT/EQ/GT ctor references (Names.registerCtor, done
-- once at optimize time -- see Optimize.Expression's makeClosedCmpCall,
-- same registerCtor calls the existing scalar CallCompare already makes)
-- so Generate.JavaScript never needs its own Names.Tracker access.
data CmpCallKind
  = KCompare Expr Expr Expr
  | KMin
  | KMax
```

- [ ] **Step 4: Extend the `Binary Expr` instance (tags 31, 32)**

In the `put` block, add after the `EqClosed` line:

```haskell
      EqClosed a b c d         -> putWord8 30 >> put a >> put b >> put c >> put d
```

becomes:

```haskell
      EqClosed a b c d         -> putWord8 30 >> put a >> put b >> put c >> put d
      CmpOpClosed a b c d      -> putWord8 31 >> put a >> put b >> put c >> put d
      CmpCallClosed a b c d    -> putWord8 32 >> put a >> put b >> put c >> put d
```

In the `get` block, add after the tag-30 case:

```haskell
          30 -> EqClosed <$> get <*> get <*> get <*> get
          _  -> fail "problem getting Opt.Expr binary"
```

becomes:

```haskell
          30 -> EqClosed <$> get <*> get <*> get <*> get
          31 -> CmpOpClosed <$> get <*> get <*> get <*> get
          32 -> CmpCallClosed <$> get <*> get <*> get <*> get
          _  -> fail "problem getting Opt.Expr binary"
```

- [ ] **Step 5: Add `Binary CmpShape`, `Binary CmpOp`, `Binary CmpCallKind`**

Right after `instance Binary ClosedEqShape`'s `get` block ends (before `instance Binary Def where`),
insert:

```haskell
instance Binary CmpShape where
  put shape =
    case shape of
      CmpLeaf         -> putWord8 0
      CmpTuple2 a b   -> putWord8 1 >> put a >> put b
      CmpTuple3 a b c -> putWord8 2 >> put a >> put b >> put c

  get =
    do  n <- getWord8
        case n of
          0 -> pure CmpLeaf
          1 -> liftM2 CmpTuple2 get get
          2 -> liftM3 CmpTuple3 get get get
          _ -> fail "problem getting Opt.CmpShape binary"


instance Binary CmpOp where
  put op =
    putWord8 $
      case op of
        OpLt -> 0
        OpLe -> 1
        OpGt -> 2
        OpGe -> 3

  get =
    do  n <- getWord8
        case n of
          0 -> pure OpLt
          1 -> pure OpLe
          2 -> pure OpGt
          3 -> pure OpGe
          _ -> fail "problem getting Opt.CmpOp binary"


instance Binary CmpCallKind where
  put kind =
    case kind of
      KCompare a b c -> putWord8 0 >> put a >> put b >> put c
      KMin           -> putWord8 1
      KMax           -> putWord8 2

  get =
    do  n <- getWord8
        case n of
          0 -> liftM3 KCompare get get get
          1 -> pure KMin
          2 -> pure KMax
          _ -> fail "problem getting Opt.CmpCallKind binary"
```

- [ ] **Step 6: Add the exhaustiveness arms in `Nitpick.Debug`**

In `compiler/src/Nitpick/Debug.hs`, after:

```haskell
    Opt.EqClosed _ _ l r -> hasDebug l || hasDebug r
```

add:

```haskell
    Opt.CmpOpClosed _ _ l r -> hasDebug l || hasDebug r
    Opt.CmpCallClosed _ l r kind ->
      hasDebug l || hasDebug r ||
      case kind of
        Opt.KCompare lt eq gt -> hasDebug lt || hasDebug eq || hasDebug gt
        Opt.KMin              -> False
        Opt.KMax              -> False
```

- [ ] **Step 7: Add the exhaustiveness arms in `Generate.Mode`**

In `compiler/src/Generate/Mode.hs`, after:

```haskell
        Opt.EqClosed _ _ l r -> merge (scan l) (scan r)
```

add:

```haskell
        Opt.CmpOpClosed _ _ l r -> merge (scan l) (scan r)
        Opt.CmpCallClosed _ l r kind ->
          merges $ scan l : scan r :
            case kind of
              Opt.KCompare lt eq gt -> [scan lt, scan eq, scan gt]
              Opt.KMin              -> []
              Opt.KMax              -> []
```

- [ ] **Step 8: Add the exhaustiveness arms in `Nitpick.WorkerRegistry`**

In `compiler/src/Nitpick/WorkerRegistry.hs`, after:

```haskell
    Opt.EqClosed _ _ l r -> exprTargets l <> exprTargets r
```

add:

```haskell
    Opt.CmpOpClosed _ _ l r -> exprTargets l <> exprTargets r
    Opt.CmpCallClosed _ l r kind ->
      exprTargets l <> exprTargets r <>
      case kind of
        Opt.KCompare lt eq gt -> exprTargets lt <> exprTargets eq <> exprTargets gt
        Opt.KMin              -> Set.empty
        Opt.KMax              -> Set.empty
```

- [ ] **Step 9: Add the codegen dispatch arms in `Generate.JavaScript.Expression`**

In the main `generate` function, after:

```haskell
    Opt.EqClosed isEq shape left right ->
      JsExpr $ generateClosedEq mode isEq shape left right
```

add:

```haskell
    Opt.EqClosed isEq shape left right ->
      JsExpr $ generateClosedEq mode isEq shape left right

    Opt.CmpOpClosed op shape left right ->
      JsExpr $ generateCmpOpClosed mode op shape left right

    Opt.CmpCallClosed shape left right kind ->
      JsExpr $ generateCmpCallClosed mode shape left right kind
```

- [ ] **Step 10: Write `generateCmpOpClosed` and its helpers**

Find `foldAnd`'s definition (the last function in the "closed eq" codegen section, right before the
`-- TAIL CALL` comment):

```haskell
foldAnd :: [JS.Expr] -> JS.Expr
foldAnd exprs =
  case exprs of
    []       -> JS.Bool True
    [e]      -> e
    e : rest -> JS.Infix JS.OpAnd e (foldAnd rest)



-- TAIL CALL
```

Insert between `foldAnd`'s definition and `-- TAIL CALL`:

```haskell
foldAnd :: [JS.Expr] -> JS.Expr
foldAnd exprs =
  case exprs of
    []       -> JS.Bool True
    [e]      -> e
    e : rest -> JS.Infix JS.OpAnd e (foldAnd rest)



-- CLOSED TUPLE COMPARE


-- Emitted for Opt.CmpOpClosed. Dev mode calls the existing `cmp` helper
-- unchanged, with the same (idealOp, backupOp, backupInt) triple
-- generateBasicsCall already uses per operator -- byte-identical to
-- today's output, since `cmp`'s isLiteral fast path can never fire for a
-- Tuple-typed operand (Tuples are always JS object literals, never
-- JS.String/Float/Int/Bool). Prod mode recursively lowers CmpShape into a
-- direct short-circuiting boolean chain, no intermediate ordinal value.
generateCmpOpClosed :: Mode.Mode -> Opt.CmpOp -> Opt.CmpShape -> Opt.Expr -> Opt.Expr -> JS.Expr
generateCmpOpClosed mode op shape left right =
  let
    jsLeft = generateJsExpr mode left
    jsRight = generateJsExpr mode right
  in
  case mode of
    Mode.Dev _ ->
      case op of
        Opt.OpLt -> cmp JS.OpLt JS.OpLt   0    jsLeft jsRight
        Opt.OpLe -> cmp JS.OpLe JS.OpLt   1    jsLeft jsRight
        Opt.OpGt -> cmp JS.OpGt JS.OpGt   0    jsLeft jsRight
        Opt.OpGe -> cmp JS.OpGe JS.OpGt (-1)   jsLeft jsRight

    Mode.Prod _ _ ->
      generateCmpBool op shape jsLeft jsRight


-- Direct short-circuiting boolean chain for one comparison operator: all
-- slots but the last are compared via generateOrdinal (need the full
-- three-way result to decide whether to move on to the next slot or
-- resolve now), the last slot uses the operator's actual relation
-- directly. E.g. for OpLt on a flat Tuple2: `x.a !== y.a ? x.a < y.a :
-- x.b < y.b`.
generateCmpBool :: Opt.CmpOp -> Opt.CmpShape -> JS.Expr -> JS.Expr -> JS.Expr
generateCmpBool op shape exprL exprR =
  case shape of
    Opt.CmpLeaf ->
      JS.Infix (finalRelOp op) exprL exprR

    Opt.CmpTuple2 s0 s1 ->
      prefixStep op (slotOrdinal Index.first s0 exprL exprR) $
        generateCmpBool op s1 (slotAccess Index.second exprL) (slotAccess Index.second exprR)

    Opt.CmpTuple3 s0 s1 s2 ->
      prefixStep op (slotOrdinal Index.first s0 exprL exprR) $
        prefixStep op (slotOrdinal Index.second s1 exprL exprR) $
          generateCmpBool op s2 (slotAccess Index.third exprL) (slotAccess Index.third exprR)


-- If the prefix slot's ordinal is nonzero, the whole comparison is
-- decided by it (using the operator's strict prefix relation: `<` for
-- OpLt/OpLe, `>` for OpGt/OpGe -- ties must fall through to the next
-- slot regardless of `<` vs `<=`). Otherwise defer to `rest`.
prefixStep :: Opt.CmpOp -> JS.Expr -> JS.Expr -> JS.Expr
prefixStep op ordinal rest =
  JS.If (JS.Infix JS.OpNe ordinal (JS.Int 0))
    (JS.Infix (prefixRelOp op) ordinal (JS.Int 0))
    rest


-- Full lexicographic ordinal (-1/0/1) for two same-shaped CmpShape-typed
-- JS expressions -- the "compute once, read three ways" primitive used
-- both by generateCmpBool's prefix-slot tie-breaks and by
-- generateCmpCallClosed's `compare`/`min`/`max` codegen. Note: a prefix
-- slot's ordinal subexpression is referenced twice by prefixStep/ordStep
-- (once in the nonzero check, once as the resolved value) -- this
-- duplicates generated code by a small constant factor per nesting level,
-- which is fine in practice since real Tuple nesting is shallow (this
-- scope's own MVP fixtures never go past 2 levels); a genuine shared JS
-- temp per level would need an IIFE per level, trading code size for
-- runtime call overhead, not obviously a win.
generateOrdinal :: Opt.CmpShape -> JS.Expr -> JS.Expr -> JS.Expr
generateOrdinal shape exprL exprR =
  case shape of
    Opt.CmpLeaf ->
      JS.If (JS.Infix JS.OpLt exprL exprR) (JS.Int (-1))
        (JS.If (JS.Infix JS.OpGt exprL exprR) (JS.Int 1) (JS.Int 0))

    Opt.CmpTuple2 s0 s1 ->
      ordStep (slotOrdinal Index.first s0 exprL exprR) $
        generateOrdinal s1 (slotAccess Index.second exprL) (slotAccess Index.second exprR)

    Opt.CmpTuple3 s0 s1 s2 ->
      ordStep (slotOrdinal Index.first s0 exprL exprR) $
        ordStep (slotOrdinal Index.second s1 exprL exprR) $
          generateOrdinal s2 (slotAccess Index.third exprL) (slotAccess Index.third exprR)


ordStep :: JS.Expr -> JS.Expr -> JS.Expr
ordStep ordinal rest =
  JS.If (JS.Infix JS.OpNe ordinal (JS.Int 0)) ordinal rest


slotOrdinal :: Index.ZeroBased -> Opt.CmpShape -> JS.Expr -> JS.Expr -> JS.Expr
slotOrdinal index subShape exprL exprR =
  generateOrdinal subShape (slotAccess index exprL) (slotAccess index exprR)


slotAccess :: Index.ZeroBased -> JS.Expr -> JS.Expr
slotAccess index expr =
  JS.Access expr (JsName.fromIndex index)


finalRelOp :: Opt.CmpOp -> JS.InfixOp
finalRelOp op =
  case op of
    Opt.OpLt -> JS.OpLt
    Opt.OpLe -> JS.OpLe
    Opt.OpGt -> JS.OpGt
    Opt.OpGe -> JS.OpGe


prefixRelOp :: Opt.CmpOp -> JS.InfixOp
prefixRelOp op =
  case op of
    Opt.OpLt -> JS.OpLt
    Opt.OpLe -> JS.OpLt
    Opt.OpGt -> JS.OpGt
    Opt.OpGe -> JS.OpGt


-- Emitted for Opt.CmpCallClosed. Dev mode calls the existing
-- generateGlobalCall unchanged, with the original Basics function name --
-- byte-identical to today's `A2(global, left, right)`. Prod mode: KMin/
-- KMax use a single short-circuit boolean condition (generateCmpBool)
-- with left/right as the two ternary branches -- no intermediate value.
-- KCompare needs the ordinal read three ways (LT/EQ/GT), so it's
-- genuinely computed once via a small IIFE built directly at the JS.Expr
-- level (JS.Function/JS.Var/JS.IfStmt/JS.Return) -- this construction is
-- entirely local to this function, never touches Opt.Expr/the .elmo, and
-- is therefore invisible to Dev-mode codegen (which never reaches this
-- branch at all): it cannot violate the byte-identical-Dev-output
-- contract the way a generic Opt.Let+Opt.If built at the Optimize.
-- Expression layer would have (see the design spec's Correction 2).
generateCmpCallClosed :: Mode.Mode -> Opt.CmpShape -> Opt.Expr -> Opt.Expr -> Opt.CmpCallKind -> JS.Expr
generateCmpCallClosed mode shape left right kind =
  case mode of
    Mode.Dev _ ->
      generateGlobalCall ModuleName.basics (cmpCallKindName kind)
        (map (generateJsExpr mode) [left, right])

    Mode.Prod _ _ ->
      let
        jsLeft = generateJsExpr mode left
        jsRight = generateJsExpr mode right
      in
      case kind of
        Opt.KMin -> JS.If (generateCmpBool Opt.OpLt shape jsLeft jsRight) jsLeft jsRight
        Opt.KMax -> JS.If (generateCmpBool Opt.OpGt shape jsLeft jsRight) jsLeft jsRight

        Opt.KCompare lt eq gt ->
          let
            ordName = JsName.fromLocal "_ord"
            ordRef = JS.Ref ordName
          in
          JS.Call
            ( JS.Function Nothing []
                [ JS.Var ordName (generateOrdinal shape jsLeft jsRight)
                , JS.IfStmt (JS.Infix JS.OpLt ordRef (JS.Int 0))
                    (JS.Return (generateJsExpr mode lt))
                    (JS.IfStmt (JS.Infix JS.OpEq ordRef (JS.Int 0))
                      (JS.Return (generateJsExpr mode eq))
                      (JS.Return (generateJsExpr mode gt)))
                ]
            )
            []


cmpCallKindName :: Opt.CmpCallKind -> Name.Name
cmpCallKindName kind =
  case kind of
    Opt.KCompare _ _ _ -> "compare"
    Opt.KMin           -> "min"
    Opt.KMax           -> "max"



-- TAIL CALL
```

(`Index.first`/`second`/`third`, `JsName.fromIndex`, `JsName.fromLocal`, `JS.Ref`, `JS.Var`, `JS.IfStmt`,
`JS.Return`, `JS.Function`, `JS.Call`, `JS.If`, `JS.Infix`, `JS.OpLt`/`OpLe`/`OpGt`/`OpGe`/`OpEq`/`OpNe`,
`generateGlobalCall`, `cmp`, `ModuleName.basics` are all already imported/defined/used elsewhere in this
file — no new imports needed.)

- [ ] **Step 11: Build and verify no warnings**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: clean build. `CmpOpClosed`/`CmpCallClosed` and all their match arms compile and are fully
codegen-capable, but nothing constructs one yet (dead code — no warning, since these are exported
constructors plus live pattern-match arms, not unused bindings).

- [ ] **Step 12: Commit**

```bash
git add compiler/src/AST/Optimized.hs compiler/src/Nitpick/Debug.hs compiler/src/Generate/Mode.hs compiler/src/Nitpick/WorkerRegistry.hs compiler/src/Generate/JavaScript/Expression.hs
git commit -m "feat: add Opt.CmpOpClosed/CmpCallClosed nodes with full Dev/Prod codegen (unused until Optimize.Expression wires them up)"
```

---

### Task 4: Wire `Optimize.Expression` to emit `CmpOpClosed`/`CmpCallClosed`

**Files:**
- Modify: `compiler/src/Optimize/Expression.hs`

**Interfaces:**
- Consumes: `Hints._cmpHints` (Task 2), `Opt.CmpOpClosed`/`Opt.CmpCallClosed`/`Opt.CmpShape`/`Opt.CmpOp`/
  `Opt.CmpCallKind` (Task 3), `isCheap` (existing, same file), `Names.registerGlobal`/`registerKernel`/
  `registerCtor` (existing, `Optimize.Names`).
- Produces: this is the task that makes the feature "go live" — closed-tuple `<`/`<=`/`>`/`>=`/`compare`/
  `min`/`max` source expressions now actually compile through the two new nodes.

- [ ] **Step 1: Add `toClosedCmpTarget` and `registerClosedCmpOp` (for the four operators)**

Right after `registerClosedEq`'s definition (find the comment `-- PRIM CALL` that follows it — insert
these new functions right before that comment), add:

```haskell


-- Like toClosedEqTarget, but for `<`/`<=`/`>`/`>=` on a closed
-- Tuple2/Tuple3-of-comparable-scalars shape (see Type.Solve's
-- resolveCmpProbes).
toClosedCmpTarget :: Hints -> A.Region -> ModuleName.Canonical -> Name.Name -> Maybe (Opt.CmpOp, Opt.CmpShape)
toClosedCmpTarget hints region home name =
  if home /= ModuleName.basics then
    Nothing
  else
    do  op <-
          case name of
            "lt" -> Just Opt.OpLt
            "le" -> Just Opt.OpLe
            "gt" -> Just Opt.OpGt
            "ge" -> Just Opt.OpGe
            _    -> Nothing
        shape <- Map.lookup region (_cmpHints hints)
        Just (op, shape)


-- Builds the Opt.CmpOpClosed node. Registers the same phantom
-- Basics.lt/le/gt/ge global edge the generic fallback branch would have
-- registered for this call site -- not because the CmpOpClosed node we
-- build actually calls through that global, but so the dead-code-
-- elimination reachability graph coming out of this module stays
-- identical to what it was before this shortcut existed (same reasoning
-- as registerClosedEq -- see that function's comment). Also registers the
-- Utils kernel dependency: unlike registerClosedEq's Dev fallback,
-- generateCmpOpClosed's Dev fallback goes through the existing `cmp`
-- helper, which references _Utils_cmp directly (not through the Basics
-- global at all), so the kernel chunk must stay reachable too.
registerClosedCmpOp :: Name.Name -> Opt.CmpOp -> Opt.CmpShape -> Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
registerClosedCmpOp name op shape optLeft optRight =
  do  _ <- Names.registerGlobal ModuleName.basics name
      Names.registerKernel Name.utils (Opt.CmpOpClosed op shape optLeft optRight)
```

- [ ] **Step 2: Rewrite the `Can.Binop` case to also check `toClosedCmpTarget`**

Replace:

```haskell
    Can.Binop _ home name _ left right ->
      case Map.lookup region (_primHints hints) >>= toPrimBinop home name of
        Just prim ->
          Opt.PrimOp prim
            <$> optimize hints cycle left
            <*> optimize hints cycle right

        Nothing ->
          case toClosedEqTarget hints region home name of
            Nothing ->
              do  optFunc <- Names.registerGlobal home name
                  optLeft <- optimize hints cycle left
                  optRight <- optimize hints cycle right
                  return (Opt.Call optFunc [optLeft, optRight])

            Just (isEq, shape) ->
              do  optLeft <- optimize hints cycle left
                  optRight <- optimize hints cycle right
                  if isCheap optLeft && isCheap optRight
                    then registerClosedEq shape isEq optLeft optRight
                    else
                      do  optFunc <- Names.registerGlobal home name
                          return (Opt.Call optFunc [optLeft, optRight])
```

with:

```haskell
    Can.Binop _ home name _ left right ->
      case Map.lookup region (_primHints hints) >>= toPrimBinop home name of
        Just prim ->
          Opt.PrimOp prim
            <$> optimize hints cycle left
            <*> optimize hints cycle right

        Nothing ->
          case toClosedEqTarget hints region home name of
            Just (isEq, shape) ->
              do  optLeft <- optimize hints cycle left
                  optRight <- optimize hints cycle right
                  if isCheap optLeft && isCheap optRight
                    then registerClosedEq shape isEq optLeft optRight
                    else
                      do  optFunc <- Names.registerGlobal home name
                          return (Opt.Call optFunc [optLeft, optRight])

            Nothing ->
              case toClosedCmpTarget hints region home name of
                Just (op, shape) ->
                  do  optLeft <- optimize hints cycle left
                      optRight <- optimize hints cycle right
                      if isCheap optLeft && isCheap optRight
                        then registerClosedCmpOp name op shape optLeft optRight
                        else
                          do  optFunc <- Names.registerGlobal home name
                              return (Opt.Call optFunc [optLeft, optRight])

                Nothing ->
                  do  optFunc <- Names.registerGlobal home name
                      optLeft <- optimize hints cycle left
                      optRight <- optimize hints cycle right
                      return (Opt.Call optFunc [optLeft, optRight])
```

(This is a pure reordering plus one new nested branch — the two pre-existing branches, `toClosedEqTarget`
returning `Just` and the deepest `Nothing`, are byte-for-byte the same code as before this task.)

- [ ] **Step 3: Add `toClosedCmpCall` and `makeClosedCmpCall` (for `compare`/`min`/`max`)**

Right after `isCheap`'s definition (find the comment `-- \`min a b\` becomes...` that precedes
`makePrimCall` — insert these new functions right before that comment), add:

```haskell


-- Like toPrimCall, but for closed-tuple compare/min/max (see Type.Solve's
-- resolveCmpProbes). Checked only when toPrimCall's own scalar PrimType
-- hint lookup fails (see the Can.Call case below), so a genuinely scalar
-- compare/min/max keeps taking the existing CallCompare/CallMin/CallMax
-- path unchanged.
toClosedCmpCall :: Hints -> A.Region -> Can.Expr -> [Can.Expr] -> Maybe (Name.Name, Opt.CmpShape)
toClosedCmpCall hints region (A.At _ func) args =
  case (func, args) of
    (Can.VarForeign home name _, [_, _])
      | home == ModuleName.basics && (name == "compare" || name == "min" || name == "max") ->
          (,) name <$> Map.lookup region (_cmpHints hints)

    _ ->
      Nothing


-- Builds the Opt.CmpCallClosed node, registering the same phantom
-- Basics.compare/min/max global edge registerClosedCmpOp documents, for
-- the same DCE-reachability reason. Unlike registerClosedCmpOp, no Utils
-- kernel registration is needed: generateCmpCallClosed's Dev fallback
-- goes through generateGlobalCall (the ordinary Basics.compare/min/max
-- global), not a direct kernel reference. `compare` additionally
-- registers the LT/EQ/GT ctor refs its Prod-mode codegen embeds -- same
-- registerCtor calls the existing scalar CallCompare already makes.
makeClosedCmpCall :: Name.Name -> Opt.CmpShape -> Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
makeClosedCmpCall name shape optLeft optRight =
  do  _ <- Names.registerGlobal ModuleName.basics name
      case name of
        "compare" ->
          do  lt <- Names.registerCtor ModuleName.basics "LT" Index.first Can.Enum
              eq <- Names.registerCtor ModuleName.basics "EQ" Index.second Can.Enum
              gt <- Names.registerCtor ModuleName.basics "GT" Index.third Can.Enum
              pure (Opt.CmpCallClosed shape optLeft optRight (Opt.KCompare lt eq gt))

        "min" -> pure (Opt.CmpCallClosed shape optLeft optRight Opt.KMin)
        _     -> pure (Opt.CmpCallClosed shape optLeft optRight Opt.KMax)
```

- [ ] **Step 4: Wire `toClosedCmpCall`/`makeClosedCmpCall` into the `Can.Call` case**

Replace:

```haskell
    Can.Call func args ->
      case toPrimCall hints region func args of
        Just spec ->
          do  optArgs <- traverse (optimize hints cycle) args
              case optArgs of
                [left, right] | isCheap left && isCheap right ->
                  makePrimCall spec left right

                _ ->
                  do  optFunc <- optimize hints cycle func
                      pure (Opt.Call optFunc optArgs)

        Nothing ->
          Opt.Call
            <$> optimize hints cycle func
            <*> traverse (optimize hints cycle) args
```

with:

```haskell
    Can.Call func args ->
      case toPrimCall hints region func args of
        Just spec ->
          do  optArgs <- traverse (optimize hints cycle) args
              case optArgs of
                [left, right] | isCheap left && isCheap right ->
                  makePrimCall spec left right

                _ ->
                  do  optFunc <- optimize hints cycle func
                      pure (Opt.Call optFunc optArgs)

        Nothing ->
          case toClosedCmpCall hints region func args of
            Just (name, shape) ->
              do  optArgs <- traverse (optimize hints cycle) args
                  case optArgs of
                    [left, right] | isCheap left && isCheap right ->
                      makeClosedCmpCall name shape left right

                    _ ->
                      do  optFunc <- optimize hints cycle func
                          pure (Opt.Call optFunc optArgs)

            Nothing ->
              Opt.Call
                <$> optimize hints cycle func
                <*> traverse (optimize hints cycle) args
```

- [ ] **Step 5: Build and verify no warnings**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: clean build. The feature is now fully wired end to end.

- [ ] **Step 6: Commit**

```bash
git add compiler/src/Optimize/Expression.hs
git commit -m "feat: emit Opt.CmpOpClosed/CmpCallClosed for closed-tuple compare sites"
```

---

### Task 5: End-to-end correctness verification (real compiler, scratch project)

**Files:**
- None (no source changes) — verification only, using a scratch Elm project outside this repo.

**Interfaces:**
- Consumes: the `elm` binary built by Task 4.
- Produces: confirmation that Dev output is byte-identical to pre-plan, and that Prod output for every
  positive/negative case matches the design spec's scope.

- [ ] **Step 1: Set up a scratch project with a fresh `ELM_HOME`**

```bash
mkdir -p /tmp/claude-1000/-home-andre-Workspace-Projects-Freinet-elm-compiler/*/scratchpad/tuplecmp-verify/src
```

(Use this session's actual scratchpad path.) Create `elm.json` there with `"elm-version": "0.19.2"` and an
`elm/core` dependency only (mirror the shape of any prior scratch-project `elm.json` used for earlier
plans in this repo, e.g. `closed-type-structural-equality`'s verification run).

- [ ] **Step 2: Write the fixture**

Create `src/Bench.elm` covering every positive and negative case from the design spec's Scope section:

```elm
module Bench exposing (main)


-- Positive: flat Tuple2, Tuple3, nested tuple-of-tuple, Char pair

flatLt : (Int, Int) -> (Int, Int) -> Bool
flatLt a b = a < b

flatLe : (Int, Int) -> (Int, Int) -> Bool
flatLe a b = a <= b

flatGt : (Int, Int) -> (Int, Int) -> Bool
flatGt a b = a > b

flatGe : (Int, Int) -> (Int, Int) -> Bool
flatGe a b = a >= b

flat3Compare : (Int, Float, String) -> (Int, Float, String) -> Order
flat3Compare a b = compare a b

flat3Min : (Int, Float, String) -> (Int, Float, String) -> (Int, Float, String)
flat3Min a b = min a b

flat3Max : (Int, Float, String) -> (Int, Float, String) -> (Int, Float, String)
flat3Max a b = max a b

nestedLt : ((Int, Int), (Int, Int)) -> ((Int, Int), (Int, Int)) -> Bool
nestedLt a b = a < b

nestedCompare : ((Int, Int), (Int, Int)) -> ((Int, Int), (Int, Int)) -> Order
nestedCompare a b = compare a b

charLt : (Char, Char) -> (Char, Char) -> Bool
charLt a b = a < b

charCompare : (Char, Char) -> (Char, Char) -> Order
charCompare a b = compare a b


-- Negative: generic/row-poly (comparable type variable, never resolves)

genericLt : comparable -> comparable -> Bool
genericLt a b = a < b

genericCompare : comparable -> comparable -> Order
genericCompare a b = compare a b


-- Negative: List-typed compare (List is comparable, but never unrolled)

listLt : List Int -> List Int -> Bool
listLt a b = a < b

listCompare : List Int -> List Int -> Order
listCompare a b = compare a b


-- Negative: tuple slot is a Record (not a comparable scalar/tuple)
-- (only expressible by writing a monomorphic helper that never actually
-- gets called with a real Record, since Record isn't comparable either --
-- this negative case doesn't type-check in Elm at all, so it's dropped;
-- see design spec's "Explicitly out of scope" -- a Record/Union tuple slot
-- can only arise as dead code the type checker never accepts, so there is
-- no fixture for it)


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
```

(Note: unlike `EqClosed`'s fixture, a Record/Union tuple-slot negative case is not expressible — Elm's
type checker already rejects `compare`/`<` on any type containing a non-comparable component, so there is
no well-typed program that could exercise that fallback path; the `toClosedCmpShape` probe's handling of
that case is defensive/unreachable in practice, not something to verify via a compiled fixture.)

- [ ] **Step 3: Compile in Dev mode and diff against pre-plan output**

Using the Docker recipe from `CLAUDE.md`'s "Running the freshly built compiler" section, compile with
`elm make src/Bench.elm --output elm-dev.js` using the Task-4 binary. Separately, check out the commit
immediately before Task 1 (`git stash` or a second worktree), build that binary, and compile the same
`Bench.elm` to `elm-dev-before.js` with a **separate fresh `ELM_HOME`** (wire-format changed, must not
reuse a cache built by the other binary). Diff:

```bash
diff elm-dev-before.js elm-dev.js
```

Expected: **no difference** (byte-identical). If there is a difference, stop and investigate before
continuing — this is the sharpest test of the design spec's Correction 2 (the two new nodes' Dev-mode
codegen must reconstruct today's exact output).

- [ ] **Step 4: Compile in Prod mode and inspect the generated JS**

```bash
elm make src/Bench.elm --optimize --output elm-prod.js
```

Inspect `elm-prod.js` for:
- `flatLt`/`flatLe`/`flatGt`/`flatGe` compile to a direct 2-component short-circuit chain over `.a`/`.b`
  — no call to any `_Utils_*` function.
- `flat3Compare`/`flat3Min`/`flat3Max` compile to inlined code referencing `.a`/`.b`/`.c` directly — no
  `A2`/F2 dispatch, no call to `_Utils_compare`/`_Utils_cmp`. `flat3Compare` specifically should show the
  small IIFE shape (`(function(){ var _ord = ...; if (...) return ...; ... })()`).
- `nestedLt`/`nestedCompare` show the same shapes but with one extra level of `.a.a`/`.a.b`/`.b.a`/`.b.b`
  access.
- `charLt`/`charCompare` compile the same way as the Int-based cases (plain `<`/`===` on the Char slots,
  which are raw JS strings in Prod).
- `genericLt`/`genericCompare`, `listLt`/`listCompare` all **still** call through the generic path (`cmp`/
  `_Utils_cmp` for the operators, `A2(...)` into `_Utils_compare` for compare) — confirms the negative
  cases correctly keep the generic path.

- [ ] **Step 5: Execute under Node and confirm correctness**

Write a small Node harness (`bench-runner.js`, following the pattern noted in
[[prim-binop-specialization-plan]]'s memory entry) that calls each of the 11 positive-case functions with
several argument pairs (equal, differing in the first component, differing only in the last component,
for the nested case differing only in the innermost slot) and prints the results. Confirm every result
matches Elm's documented `comparable` ordering — in particular: `(1, 2) < (1, 3)` is `True` but `(2, 1) <
(1, 3)` is `False` (first-component-wins semantics), and `compare (1,2) (1,2)` is `EQ`.

- [ ] **Step 6: Record the verification result**

No code changes in this task — if all checks pass, proceed to Task 6. If any check fails, return to the
relevant earlier task, fix, rebuild, and re-run this task's steps from Step 3.

---

### Task 6: Two-binary performance benchmark

**Files:**
- None (no source changes) — benchmarking only.

**Interfaces:**
- Consumes: the Task 4 binary (`after`) and the pre-Task-1 binary (`before`), both built with a fresh,
  separate `ELM_HOME`/`elm-stuff` each (per [[elm-stuff-cache-contamination-finding]] — never compile
  both variants in the same project directory).

- [ ] **Step 1: Reuse the Task 5 fixture at scale**

Extend `Bench.elm`'s `flatLt`/`flat3Compare`/`nestedLt`/`charLt` (and their `compare`/`min`/`max`
counterparts) fixtures to run in a tight loop over generated arrays of tuple values (mirroring
[[tuple-compare-closed-shape-spike]]'s exact methodology: micro-loop comparing generated pairs, plus an
`Array.sort`-equivalent sort-by-tuple-key benchmark) at sizes 1,000 / 20,000 / 200,000, matching the
corrected spike's (`bench2.js`) fixture shapes.

- [ ] **Step 2: Build both binaries with `--optimize`, separate `ELM_HOME`s**

```bash
# before
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-before:/work/dist-newstyle \
  -v <scratch-project>:/test -v elm-home-before:/root/.elm \
  haskell:9.8.4 bash -c '...'   # checked out at the pre-Task-1 commit

# after
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v <scratch-project>:/test -v elm-home-after:/root/.elm \
  haskell:9.8.4 bash -c '...'   # at this plan's final commit
```

- [ ] **Step 3: Run interleaved, separate-process benchmarks**

Follow the exact methodology already established in this fork's memory (see
[[closed-type-structural-equality-spike]]'s "Methodik" section and
[[prim-binop-specialization-plan]]'s benchmark section): interleaved separate Node processes, ~500ms-1s
per-process rep calibration, 1 discarded warmup pair, at least 9-15 counted reps per size, median and
average both reported, checksum compared on every single run.

- [ ] **Step 4: Compare against the corrected spike's numbers**

Expected range, per the corrected spike (`bench2.js`): operators (`<`/`<=`/`>`/`>=`) 1.41x-2.19x,
`compare`/`min`/`max` 1.41x-2.53x, sort 1.25x-1.82x. Record the actual measured numbers. If the
real-compiler numbers diverge meaningfully from the hand-patch spike (in either direction), investigate
before declaring the feature complete — this mirrors the discrepancy
[[list-mapn-unwrapped-kernel-plan]] found between an isolated hand-spike and the real, fully-wired
compiler, which turned out to matter for the accept/reject decision.

- [ ] **Step 5: Report the result**

Summarize measured speedups for both operator families, all four shapes (flat Tuple2, flat Tuple3,
nested, Char pair), at all three sizes. This is the final task in the plan — no further code changes are
anticipated unless Task 5 or Task 6 surfaced a problem.

---

## Self-Review Notes

- **Spec coverage:** every scope item in the design spec — closed Tuple2/Tuple3 (flat and nested), Char
  via a separate probe (not shared `PrimType`), both operator and call-site forms, `isCheap` gating,
  Dev-output stability, the two corrections (baseline modeling, byte-identity-incompatible single-node
  design) — is covered: Tasks 1-4 implement it, Task 5 verifies the byte-identity/negative-case boundary
  explicitly, Task 6 verifies the corrected performance claim.
- **No placeholders:** every step above contains complete, non-elided code; no step says "add similar
  handling" without showing the actual diff.
- **Type/name consistency check:** `Hints` gains `_cmpHints :: Map.Map A.Region Opt.CmpShape` in Task 2
  and is read only in Task 4's `toClosedCmpTarget`/`toClosedCmpCall` — type and name match.
  `Opt.CmpOpClosed`/`Opt.CmpCallClosed`/`Opt.CmpShape`/`Opt.CmpOp`/`Opt.CmpCallKind` are defined in Task 3
  and constructed only in Task 4 (`registerClosedCmpOp`, `makeClosedCmpCall`) — constructor arities match
  (`CmpOpClosed :: CmpOp -> CmpShape -> Expr -> Expr -> Expr`, called as `Opt.CmpOpClosed op shape optLeft
  optRight`; `CmpCallClosed :: CmpShape -> Expr -> Expr -> CmpCallKind -> Expr`, called as
  `Opt.CmpCallClosed shape optLeft optRight kind`, both matching Task 3's definitions and Binary instance
  argument order). `Type.CmpShape`/`Type.toClosedCmpShape` (Task 1) are consumed only in Task 2's
  `addCmpProbe`/`resolveCmpProbes` and converted to `Opt.CmpShape` once in `Optimize.Module.toOptCmpShape`
  — the two `CmpShape` types are never confused across the `Type.`/`Opt.` qualifier boundary anywhere in
  the plan. `Type.Solve.run`'s new arity (still 3 args: `home`, `unions`, `constraint` — only the *return*
  tuple grows) matches its Task 2 Step 3 call site in `Compile.hs`.
