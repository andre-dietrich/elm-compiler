# Closed-Type Structural Equality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `==`/`/=` on a closed (non-row-polymorphic) Record or a closed, non-generic,
`Can.Normal`-ctor Union — whose fields/ctor-args are all statically proven Int/Float/Bool/String —
compile in `--optimize` builds to a flat chain of named `===` reads instead of the generic
`_Utils_eq`/`_Utils_eqHelp` kernel walk.

**Architecture:** Extends the existing `CProbe`/`Type.Solve` pipeline (the same one
`Type.toPrimType`/`_primHints` already uses for scalar `==`/`<`/`++` specialization) with two more
resolution passes over the same probe list, feeding a new `AST.Optimized` node (`EqClosed`) that
`Optimize.Expression` emits (gated on `isCheap`, mirroring the existing compare/min/max inlining) and
`Generate.JavaScript.Expression` lowers to a flat `&&`-chain of `===` in Prod mode only — Dev mode
reproduces the prior `_Utils_eq`/`_Utils_neq` call byte-for-byte. Full design rationale, scope
boundaries, and file list: `docs/superpowers/specs/2026-07-23-closed-type-structural-equality-design.md`
— read it before starting; this plan assumes its scope decisions (flat fields only, same-module
non-generic `Can.Normal` unions only, Prod-only codegen) without re-litigating them.

**Tech Stack:** Haskell (GHC 9.8.4 via the `haskell:9.8.4` Docker image), `cabal build`, no local
toolchain — see `CLAUDE.md`'s Build section for the exact Docker invocation. No automated test suite
exists in this repo; verification is manual (build + scratch Elm project + JS inspection/execution),
per `CLAUDE.md`'s Testing section.

## Global Constraints

- `-Wall -Werror` is baked into `elm.cabal` — any warning (unused binds, incomplete patterns, unused
  imports) fails the build. Every task's "build" step must produce a clean, warning-free build.
- Every task that changes `AST.Optimized`'s `Expr` type is a wire-format change: after Task 3, any
  previously-built `.elmo`/`.elmi` cache (project `elm-stuff/`, `ELM_HOME` package cache) becomes
  unreadable ("Corrupt File") until deleted. Use a **fresh** `ELM_HOME` volume for any scratch-project
  compile from Task 3 onward.
- Dev-mode (`elm make` without `--optimize`) JS output must be **byte-identical** before and after this
  entire plan, for every program — this is verified explicitly in Task 5.
- Follow `CLAUDE.md`'s Docker build recipe verbatim for every "run the build" step in this plan; don't
  invent a different invocation.

---

### Task 1: Closedness/primitive probes in `Type.Type`

**Files:**
- Modify: `compiler/src/Type/Type.hs`

**Interfaces:**
- Consumes: `PrimType(..)`, `toPrimType` (existing, same file), `Variable`, `Descriptor(..)`,
  `Content(..)`, `FlatType(..)` (existing, same file), `Can.Union(..)`, `Can.Ctor(..)`,
  `Can.CtorOpts(..)`, `Can.Type(..)`, `Can.AliasType(..)` (from `AST.Canonical`, already imported as
  `Can` in this file).
- Produces (used by Task 2):
  - `toClosedPrimFields :: Variable -> IO (Maybe (Set.Set Name.Name))`
  - `toClosedUnionEqArity :: ModuleName.Canonical -> Map.Map Name.Name Can.Union -> Variable -> IO (Maybe Int)`

- [ ] **Step 1: Add the two new functions to the export list**

In `compiler/src/Type/Type.hs`, the module export list currently ends with (around line 13):

```haskell
  , PrimType(..)
  , toPrimType
  , toClosedFields
```

Change it to:

```haskell
  , PrimType(..)
  , toPrimType
  , toClosedFields
  , toClosedPrimFields
  , toClosedUnionEqArity
```

- [ ] **Step 2: Write `toClosedPrimFields` right after `toClosedFields`**

Find `toClosedFields`'s definition (ends around line 295, right before the `-- WEBGL TYPES` section
comment). Insert this immediately after it, before `-- WEBGL TYPES`:

```haskell

-- CLOSED PRIMITIVE-FIELD RECORD PROBES
--
-- Like toClosedFields, but additionally requires every field to itself be
-- a JS-primitive-safe monomorphic type (see PrimType/toPrimType above).
-- Used to prove a record-typed `==`/`/=` comparison can be lowered to a
-- flat chain of `===` field reads instead of the generic _Utils_eq walk --
-- see Type.Solve's resolveRecordEqProbes and Generate.JavaScript's
-- generateClosedEq. A record containing a nested Record/Union/List/Dict/
-- etc. field is deliberately NOT closed-prim (returns Nothing), keeping
-- the generic fallback -- this is a first pass that only handles flat
-- records of scalar fields, not recursively nested closed shapes.


toClosedPrimFields :: Variable -> IO (Maybe (Set.Set Name.Name))
toClosedPrimFields variable =
  do  (Descriptor content _ _ _) <- UF.get variable
      case content of
        Structure EmptyRecord1 ->
          return (Just Set.empty)

        Structure (Record1 fields extVar) ->
          do  maybeFieldNames <- traverse toPrimFieldName (Map.toList fields)
              case sequence maybeFieldNames of
                Nothing ->
                  return Nothing

                Just names ->
                  do  maybeExtFields <- toClosedPrimFields extVar
                      return (Set.union (Set.fromList names) <$> maybeExtFields)

        Alias _ _ _ realVariable ->
          toClosedPrimFields realVariable

        _ ->
          return Nothing


toPrimFieldName :: (Name.Name, Variable) -> IO (Maybe Name.Name)
toPrimFieldName (name, fieldVar) =
  do  maybePrim <- toPrimType fieldVar
      return (fmap (const name) maybePrim)
```

- [ ] **Step 3: Write the closed-union-equality probe, right after Step 2's code**

```haskell


-- CLOSED UNION EQUALITY PROBES
--
-- Determines whether a resolved Variable is an application of a
-- non-generic Can.Union (no type parameters) defined in the CURRENT
-- module, whose CtorOpts is Normal (excludes Enum -- raw ints at runtime,
-- no `$`/`aN` fields to compare -- and Unbox -- identity-erased, the
-- runtime value literally IS the unwrapped payload) and whose every ctor's
-- argument types are themselves JS-primitive-safe. Returns the union's
-- max ctor arity (== the Prod-mode padded object shape's field count, see
-- Optimize.Module's addUnion and Generate.JavaScript.Expression's
-- generateCtor) so Generate.JavaScript can emit a flat
-- `.$===.$ && .a1===.a1 && ...` chain.
--
-- Restricted to unions declared in the module being compiled, since only
-- that module's own Can.Union table is available here -- a union imported
-- from elsewhere keeps the generic _Utils_eq fallback. Restricted to
-- non-generic unions (no type variables) to avoid needing the
-- substitution machinery a parameterized union's ctor argument types
-- would require.


toClosedUnionEqArity :: ModuleName.Canonical -> Map.Map Name.Name Can.Union -> Variable -> IO (Maybe Int)
toClosedUnionEqArity home unions variable =
  do  (Descriptor content _ _ _) <- UF.get variable
      case content of
        Structure (App1 typeHome name []) | typeHome == home ->
          return $
            do  union <- Map.lookup name unions
                closedUnionArity union

        Alias _ _ _ realVariable ->
          toClosedUnionEqArity home unions realVariable

        _ ->
          return Nothing


closedUnionArity :: Can.Union -> Maybe Int
closedUnionArity (Can.Union vars ctors _ opts) =
  if not (null vars) || opts /= Can.Normal then
    Nothing
  else if all ctorIsPrim ctors then
    Just (foldr (\(Can.Ctor _ _ numArgs _) high -> max numArgs high) 0 ctors)
  else
    Nothing


ctorIsPrim :: Can.Ctor -> Bool
ctorIsPrim (Can.Ctor _ _ _ argTypes) =
  all (\t -> closedPrimOfCanType t /= Nothing) argTypes


closedPrimOfCanType :: Can.Type -> Maybe PrimType
closedPrimOfCanType tipe =
  case tipe of
    Can.TType typeHome name []
      | typeHome == ModuleName.basics && name == "Int"    -> Just PInt
      | typeHome == ModuleName.basics && name == "Float"  -> Just PFloat
      | typeHome == ModuleName.basics && name == "Bool"   -> Just PBool
      | typeHome == ModuleName.string && name == "String" -> Just PStr

    Can.TAlias _ _ [] (Can.Filled realType) ->
      closedPrimOfCanType realType

    Can.TAlias _ _ [] (Can.Holey realType) ->
      closedPrimOfCanType realType

    _ ->
      Nothing
```

Note: `PrimType` does not derive `Ord`, only `Eq` — `closedPrimOfCanType t /= Nothing` compiles fine
against `Maybe PrimType`'s derived `Eq` (which only needs `Eq PrimType`, already derived).

- [ ] **Step 4: Build and verify no warnings**

Run (per `CLAUDE.md`'s Build section):

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds, no warnings about `Type/Type.hs`. (`toClosedPrimFields`/
`toClosedUnionEqArity` are unused at this point, but since they're in the export list, GHC does not
warn about unused top-level exported bindings.)

- [ ] **Step 5: Commit**

```bash
git add compiler/src/Type/Type.hs
git commit -m "feat: add closed-record/closed-union prim-eq probes to Type.Type"
```

---

### Task 2: Thread the two new hint maps through `Type.Solve`, `Compile`, and `Optimize.Module`

**Files:**
- Modify: `compiler/src/Type/Solve.hs`
- Modify: `compiler/src/Compile.hs`
- Modify: `compiler/src/Optimize/Module.hs`
- Modify: `compiler/src/Optimize/Expression.hs` (only the `Hints` record — no behavior change yet)

**Interfaces:**
- Consumes: `toClosedPrimFields`, `toClosedUnionEqArity` from Task 1.
- Produces (used by Task 4): `Optimize.Expression.Hints` gains two more fields,
  `_recordEqHints :: Map.Map A.Region (Set.Set Name.Name)` and
  `_unionEqHints :: Map.Map A.Region Int`, fully populated end-to-end from `Compile.compile`. Nothing
  reads these two fields yet (Task 4 does) — this task is pure plumbing.

- [ ] **Step 1: Add the `Elm.ModuleName` import to `Type.Solve`**

In `compiler/src/Type/Solve.hs`, the import list currently starts:

```haskell
import Control.Monad
import qualified Data.Map.Strict as Map
import Data.Map.Strict ((!))
import qualified Data.Name as Name
import qualified Data.NonEmptyList as NE
import qualified Data.Set as Set
import qualified Data.Vector as Vector
import qualified Data.Vector.Mutable as MVector

import qualified AST.Canonical as Can
```

Add `import qualified Elm.ModuleName as ModuleName` right after the `AST.Canonical` import:

```haskell
import qualified AST.Canonical as Can
import qualified Elm.ModuleName as ModuleName
```

- [ ] **Step 2: Extend `run`'s signature and body**

Replace the existing `run` (lines ~33-48):

```haskell
run :: Constraint -> IO (Either (NE.List Error.Error) (Map.Map Name.Name Can.Annotation, Map.Map A.Region Type.PrimType, Map.Map A.Region (Set.Set Name.Name)))
run constraint =
  do  pools <- MVector.replicate 8 []

      (State env _ errors probes recordProbes) <-
        solve Map.empty outermostRank pools emptyState constraint

      case errors of
        [] ->
          do  annotations <- traverse Type.toAnnotation env
              hints <- resolveProbes probes
              shapeHints <- resolveRecordProbes recordProbes
              return $ Right (annotations, hints, shapeHints)

        e:es ->
          return $ Left (NE.List e es)
```

with:

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

- [ ] **Step 3: Add the two new resolve-probe passes**

Right after `addRecordProbe`'s definition (end of the `-- RECORD SHAPE HINTS` section, before
`-- SOLVER`), insert:

```haskell


-- CLOSED RECORD EQUALITY HINTS


resolveRecordEqProbes :: [(A.Region, Variable, Variable)] -> IO (Map.Map A.Region (Set.Set Name.Name))
resolveRecordEqProbes probes =
  foldM addRecordEqProbe Map.empty probes


addRecordEqProbe :: Map.Map A.Region (Set.Set Name.Name) -> (A.Region, Variable, Variable) -> IO (Map.Map A.Region (Set.Set Name.Name))
addRecordEqProbe hints (region, leftVar, rightVar) =
  do  maybeLeft <- Type.toClosedPrimFields leftVar
      maybeRight <- Type.toClosedPrimFields rightVar
      return $ case (maybeLeft, maybeRight) of
        (Just left, Just right) | left == right -> Map.insert region left hints
        _                                       -> hints



-- CLOSED UNION EQUALITY HINTS


resolveUnionEqProbes :: ModuleName.Canonical -> Map.Map Name.Name Can.Union -> [(A.Region, Variable, Variable)] -> IO (Map.Map A.Region Int)
resolveUnionEqProbes home unions probes =
  foldM (addUnionEqProbe home unions) Map.empty probes


addUnionEqProbe :: ModuleName.Canonical -> Map.Map Name.Name Can.Union -> Map.Map A.Region Int -> (A.Region, Variable, Variable) -> IO (Map.Map A.Region Int)
addUnionEqProbe home unions hints (region, leftVar, rightVar) =
  do  maybeLeft <- Type.toClosedUnionEqArity home unions leftVar
      maybeRight <- Type.toClosedUnionEqArity home unions rightVar
      return $ case (maybeLeft, maybeRight) of
        (Just left, Just right) | left == right -> Map.insert region left hints
        _                                       -> hints
```

- [ ] **Step 4: Thread the new maps through `Compile.hs`**

In `compiler/src/Compile.hs`, replace `typeCheck`:

```haskell
typeCheck :: Src.Module -> Can.Module -> Either E.Error (Map.Map Name.Name Can.Annotation, Map.Map A.Region Type.PrimType, Map.Map A.Region (Set.Set Name.Name))
typeCheck modul canonical =
  case unsafePerformIO (Type.run =<< Type.constrain canonical) of
    Right result ->
      Right result

    Left errors ->
      Left (E.BadTypes (Localizer.fromModule modul) errors)
```

with:

```haskell
typeCheck :: Src.Module -> Can.Module -> Either E.Error (Map.Map Name.Name Can.Annotation, Map.Map A.Region Type.PrimType, Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region (Set.Set Name.Name), Map.Map A.Region Int)
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
  do  canonical                         <- canonicalize pkg ifaces modul
      (annotations, hints, shapeHints)  <- typeCheck modul canonical
      ()                                <- nitpick ifaces annotations canonical
      objects                           <- optimize modul annotations hints shapeHints canonical
      return (Artifacts canonical annotations objects)
```

with:

```haskell
compile :: Pkg.Name -> Map.Map ModuleName.Raw I.Interface -> Src.Module -> Either E.Error Artifacts
compile pkg ifaces modul =
  do  canonical <- canonicalize pkg ifaces modul
      (annotations, hints, shapeHints, recordEqHints, unionEqHints) <- typeCheck modul canonical
      ()        <- nitpick ifaces annotations canonical
      objects   <- optimize modul annotations hints shapeHints recordEqHints unionEqHints canonical
      return (Artifacts canonical annotations objects)
```

Replace `optimize`:

```haskell
optimize :: Src.Module -> Map.Map Name.Name Can.Annotation -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Can.Module -> Either E.Error Opt.LocalGraph
optimize modul annotations hints shapeHints canonical =
  case snd $ R.run $ Optimize.optimize annotations hints shapeHints canonical of
    Right localGraph ->
      Right localGraph

    Left errors ->
      Left (E.BadMains (Localizer.fromModule modul) errors)
```

with:

```haskell
optimize :: Src.Module -> Map.Map Name.Name Can.Annotation -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region Int -> Can.Module -> Either E.Error Opt.LocalGraph
optimize modul annotations hints shapeHints recordEqHints unionEqHints canonical =
  case snd $ R.run $ Optimize.optimize annotations hints shapeHints recordEqHints unionEqHints canonical of
    Right localGraph ->
      Right localGraph

    Left errors ->
      Left (E.BadMains (Localizer.fromModule modul) errors)
```

(`Can._name`/`Can._unions` are plain record-field accessors on `Can.Module`, already exported by
`AST.Canonical`; `Compile.hs` already imports `qualified AST.Canonical as Can` and
`qualified Elm.ModuleName as ModuleName`, so no import changes are needed in this file.)

- [ ] **Step 5: Extend `Optimize.Expression`'s `Hints` record**

In `compiler/src/Optimize/Expression.hs`, replace the `Hints` doc comment + definition:

```haskell
-- A whole-module-derived lookup table threaded down through every optimize
-- call: resolved primitive type of comparison/append Binop call sites,
-- keyed by the Binop's region. Populated by Type.Solve from CProbe
-- constraints; see Type.Type's PrimType. Absent entries mean "not proven
-- monomorphic", keeping the generic Basics.eq/append call.
--
-- _recordShapeHints is the analogous table for record update sites: the
-- full closed field set of the record being updated, keyed by the update
-- expression's region, populated by Type.Solve from CRecordProbe
-- constraints. An absent entry means the record's type wasn't provably
-- closed at that site (e.g. still row-polymorphic), which keeps the
-- generic Object.assign-based codegen path.
data Hints =
  Hints
    { _primHints :: Map.Map A.Region Type.PrimType
    , _recordShapeHints :: Map.Map A.Region (Set.Set Name.Name)
    }
```

with:

```haskell
-- A whole-module-derived lookup table threaded down through every optimize
-- call: resolved primitive type of comparison/append Binop call sites,
-- keyed by the Binop's region. Populated by Type.Solve from CProbe
-- constraints; see Type.Type's PrimType. Absent entries mean "not proven
-- monomorphic", keeping the generic Basics.eq/append call.
--
-- _recordShapeHints is the analogous table for record update sites: the
-- full closed field set of the record being updated, keyed by the update
-- expression's region, populated by Type.Solve from CRecordProbe
-- constraints. An absent entry means the record's type wasn't provably
-- closed at that site (e.g. still row-polymorphic), which keeps the
-- generic Object.assign-based codegen path.
--
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

- [ ] **Step 6: Wire the new fields into `Optimize.Module`'s `Hints` construction**

In `compiler/src/Optimize/Module.hs`, replace:

```haskell
optimize :: Annotations -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Can.Module -> Result i [W.Warning] Opt.LocalGraph
optimize annotations primHints shapeHints (Can.Module home _ _ decls unions aliases _ effects) =
  let hints = Expr.Hints primHints shapeHints in
```

with:

```haskell
optimize :: Annotations -> Map.Map A.Region Type.PrimType -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region (Set.Set Name.Name) -> Map.Map A.Region Int -> Can.Module -> Result i [W.Warning] Opt.LocalGraph
optimize annotations primHints shapeHints recordEqHints unionEqHints (Can.Module home _ _ decls unions aliases _ effects) =
  let hints = Expr.Hints primHints shapeHints recordEqHints unionEqHints in
```

- [ ] **Step 7: Build and verify no warnings**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: clean build. At this point the compiler behaves identically to before this plan (the two new
`Hints` fields are populated but never read), so this is safe to build without any scratch-project
smoke test yet.

- [ ] **Step 8: Commit**

```bash
git add compiler/src/Type/Solve.hs compiler/src/Compile.hs compiler/src/Optimize/Module.hs compiler/src/Optimize/Expression.hs
git commit -m "feat: thread closed-record/closed-union eq hints through Type.Solve and Compile"
```

---

### Task 3: New `EqClosed` Opt node, Binary encoding, and full Prod/Dev codegen

**Files:**
- Modify: `compiler/src/AST/Optimized.hs`
- Modify: `compiler/src/Nitpick/Debug.hs`
- Modify: `compiler/src/Generate/Mode.hs`
- Modify: `compiler/src/Nitpick/WorkerRegistry.hs`
- Modify: `compiler/src/Generate/JavaScript/Expression.hs`

**Interfaces:**
- Consumes: nothing from earlier tasks directly (this task only defines and fully codegens the new
  node; nothing constructs one yet — that's Task 4).
- Produces (used by Task 4): `AST.Optimized.EqClosed :: Bool -> ClosedEqShape -> Expr -> Expr -> Expr`
  and `AST.Optimized.ClosedEqShape` with constructors `ClosedEqRecord (Set.Set Name)` and
  `ClosedEqUnion Int`.

This task must land as one atomic change: `EqClosed` is a new constructor of `Opt.Expr`, and every
exhaustive `case` over `Opt.Expr` in this codebase (`-Wall`'s incomplete-patterns check is `-Werror`)
must gain a matching arm in the same commit, or nothing in the project builds at all — including
`Generate.JavaScript.Expression`'s main codegen dispatcher, so the real codegen is written now rather
than stubbed.

- [ ] **Step 1: Add `ClosedEqShape` and the `EqClosed` constructor**

In `compiler/src/AST/Optimized.hs`, add `ClosedEqShape(..)` to the export list (right after
`PrimBinop(..)`):

```haskell
  ( Def(..)
  , Expr(..)
  , PrimBinop(..)
  , ClosedEqShape(..)
  , Global(..)
```

Add the new `Expr` constructor at the end of the `data Expr` block:

```haskell
  | Shader Shader.Source (Set.Set Name) (Set.Set Name)
  | PrimOp PrimBinop Expr Expr
```

becomes:

```haskell
  | Shader Shader.Source (Set.Set Name) (Set.Set Name)
  | PrimOp PrimBinop Expr Expr
  -- Emitted for `==`/`/=` on a closed Record or non-generic same-module
  -- closed Union type whose fields/ctor-args are all JS-primitive-safe
  -- (see Type.Type's toClosedPrimFields/toClosedUnionEqArity and
  -- Optimize.Expression's toClosedEqTarget). The Bool is True for `==`,
  -- False for `/=`. Lets Generate.JavaScript skip the generic
  -- _Utils_eq/_Utils_eqHelp keyed walk in favor of a flat chain of named
  -- field reads -- see Generate.JavaScript.Expression's generateClosedEq.
  -- Prod-mode-only codegen; Dev mode ignores the shape and keeps
  -- generating the ordinary _Utils_eq/_Utils_neq kernel call (Dev output
  -- must stay byte-identical -- see CLAUDE.md).
  | EqClosed Bool ClosedEqShape Expr Expr
```

Add the `ClosedEqShape` type right after the `PrimBinop` data declaration (after its `deriving`-free
constructor list, before `data Global`):

```haskell
data Global = Global ModuleName.Canonical Name
```

becomes:

```haskell
data ClosedEqShape
  = ClosedEqRecord (Set.Set Name)
  | ClosedEqUnion Int


data Global = Global ModuleName.Canonical Name
```

- [ ] **Step 2: Extend the `Binary Expr` instance (tag 30)**

In the `put` block, add after the `TailCallConsBase` line:

```haskell
      TailCallConsBase a b c   -> putWord8 29 >> put a >> put b >> put c
```

becomes:

```haskell
      TailCallConsBase a b c   -> putWord8 29 >> put a >> put b >> put c
      EqClosed a b c d         -> putWord8 30 >> put a >> put b >> put c >> put d
```

In the `get` block, add after the tag-29 case:

```haskell
          29 -> liftM3 TailCallConsBase get get get
          _  -> fail "problem getting Opt.Expr binary"
```

becomes:

```haskell
          29 -> liftM3 TailCallConsBase get get get
          30 -> EqClosed <$> get <*> get <*> get <*> get
          _  -> fail "problem getting Opt.Expr binary"
```

- [ ] **Step 3: Add `Binary ClosedEqShape`**

Right after the `instance Binary PrimBinop where` block ends (after its `get` case's trailing
`fail "problem getting Opt.PrimBinop binary"` line and before `instance Binary Def where`), insert:

```haskell
instance Binary ClosedEqShape where
  put shape =
    case shape of
      ClosedEqRecord a -> putWord8 0 >> put a
      ClosedEqUnion  a -> putWord8 1 >> put a

  get =
    do  n <- getWord8
        case n of
          0 -> liftM ClosedEqRecord get
          1 -> liftM ClosedEqUnion get
          _ -> fail "problem getting Opt.ClosedEqShape binary"
```

- [ ] **Step 4: Add the exhaustiveness arm in `Nitpick.Debug`**

In `compiler/src/Nitpick/Debug.hs`, after:

```haskell
    Opt.PrimOp _ l r     -> hasDebug l || hasDebug r
```

add:

```haskell
    Opt.EqClosed _ _ l r -> hasDebug l || hasDebug r
```

- [ ] **Step 5: Add the exhaustiveness arm in `Generate.Mode`**

In `compiler/src/Generate/Mode.hs`, after:

```haskell
        Opt.PrimOp _ l r     -> merge (scan l) (scan r)
```

add:

```haskell
        Opt.EqClosed _ _ l r -> merge (scan l) (scan r)
```

- [ ] **Step 6: Add the exhaustiveness arm in `Nitpick.WorkerRegistry`**

In `compiler/src/Nitpick/WorkerRegistry.hs`, after:

```haskell
    Opt.PrimOp _ l r     -> exprTargets l <> exprTargets r
```

add:

```haskell
    Opt.EqClosed _ _ l r -> exprTargets l <> exprTargets r
```

- [ ] **Step 7: Add the codegen dispatch arm in `Generate.JavaScript.Expression`**

In the main `generate` function, after:

```haskell
    Opt.PrimOp op left right ->
      JsExpr $ generatePrimOp mode op left right
```

add:

```haskell
    Opt.EqClosed isEq shape left right ->
      JsExpr $ generateClosedEq mode isEq shape left right
```

- [ ] **Step 8: Write `generateClosedEq` and its helpers**

Right after `generatePrimOp`'s definition (find it via `-- Emitted for Opt.PrimOp`; insert after that
whole function, which ends where the next top-level comment/function begins), add:

```haskell


-- Emitted for Opt.EqClosed. Dev mode keeps the exact codegen a plain
-- Basics.eq/neq call on these operands would have produced before this
-- optimization existed (_Utils_eq/_Utils_neq kernel call) -- Dev output is
-- a debugging/time-travel contract, see CLAUDE.md, so it must not change.
-- Prod mode emits a flat chain of `===` field reads instead: for a closed
-- Record, one per proven-prim field (ClosedEqRecord); for a closed Union,
-- a tag check followed by one per padded a1..aN slot (ClosedEqUnion --
-- see generateCtor's maxArity padding: every variant of a Can.Normal
-- union shares the same object shape in Prod, so comparing up to the
-- union's max arity is safe and tag-independent even though only one
-- variant's slots are "meaningful" -- the rest are `null` on both sides
-- whenever the tags already matched, since same tag implies same real
-- arity).
generateClosedEq :: Mode.Mode -> Bool -> Opt.ClosedEqShape -> Opt.Expr -> Opt.Expr -> JS.Expr
generateClosedEq mode isEq shape left right =
  case mode of
    Mode.Dev _ ->
      let
        jsLeft = generateJsExpr mode left
        jsRight = generateJsExpr mode right
      in
      if isEq then equal jsLeft jsRight else notEqual jsLeft jsRight

    Mode.Prod _ _ ->
      let
        jsLeft = generateJsExpr mode left
        jsRight = generateJsExpr mode right

        comparisons =
          case shape of
            Opt.ClosedEqRecord fields ->
              map (fieldEq mode jsLeft jsRight) (Set.toAscList fields)

            Opt.ClosedEqUnion maxArity ->
              strictEq (JS.Access jsLeft JsName.dollar) (JS.Access jsRight JsName.dollar)
                : map (slotEq jsLeft jsRight) (Index.range maxArity)

        chain =
          foldAnd comparisons
      in
      if isEq then chain else JS.Prefix JS.PrefixNot chain


fieldEq :: Mode.Mode -> JS.Expr -> JS.Expr -> Name.Name -> JS.Expr
fieldEq mode jsLeft jsRight field =
  strictEq (JS.Access jsLeft (generateField mode field)) (JS.Access jsRight (generateField mode field))


slotEq :: JS.Expr -> JS.Expr -> Index.ZeroBased -> JS.Expr
slotEq jsLeft jsRight index =
  let slot = JsName.fromIndex index in
  strictEq (JS.Access jsLeft slot) (JS.Access jsRight slot)


foldAnd :: [JS.Expr] -> JS.Expr
foldAnd exprs =
  case exprs of
    []       -> JS.Bool True
    [e]      -> e
    e : rest -> JS.Infix JS.OpAnd e (foldAnd rest)
```

(`Index.range :: Int -> [Index.ZeroBased]`, `JsName.fromIndex :: Index.ZeroBased -> JsName.Name`,
`JsName.dollar :: JsName.Name`, `Set.toAscList`, `generateField`, `strictEq`, `equal`, `notEqual` are
all already used elsewhere in this file — no new imports needed.)

- [ ] **Step 9: Build and verify no warnings**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: clean build. `EqClosed`/`ClosedEqShape` and all their new match arms compile and are fully
codegen-capable, but nothing constructs an `Opt.EqClosed` value yet (dead code — no warning, since it's
an exported constructor plus live pattern-match arms, not an unused binding).

- [ ] **Step 10: Commit**

```bash
git add compiler/src/AST/Optimized.hs compiler/src/Nitpick/Debug.hs compiler/src/Generate/Mode.hs compiler/src/Nitpick/WorkerRegistry.hs compiler/src/Generate/JavaScript/Expression.hs
git commit -m "feat: add Opt.EqClosed node with full Dev/Prod codegen (unused until Optimize.Expression wires it up)"
```

---

### Task 4: Wire `Optimize.Expression`'s `Can.Binop` handling to emit `EqClosed`

**Files:**
- Modify: `compiler/src/Optimize/Expression.hs`

**Interfaces:**
- Consumes: `Hints._recordEqHints`/`_unionEqHints` (Task 2), `Opt.EqClosed`/`Opt.ClosedEqShape` (Task 3),
  `isCheap` (existing, same file), `Names.registerKernel`/`registerFieldList` (existing,
  `Optimize.Names`).
- Produces: this is the task that makes the feature "go live" — closed-Record/closed-Union `==`/`/=`
  source expressions now actually compile through `Opt.EqClosed`.

- [ ] **Step 1: Add the hint-lookup and node-construction helpers**

Right after `toPrimBinop`'s definition (find the comment `-- PRIM CALL` that follows it — insert these
new functions right before that comment, i.e. still within the `-- CONSTRAIN`-adjacent binop-helpers
region), add:

```haskell


-- Like toPrimBinop, but for `==`/`/=` on a closed Record or closed
-- same-module non-generic Normal-ctor Union type (see Type.Solve's
-- resolveRecordEqProbes/resolveUnionEqProbes). A region can never match
-- both hint maps (a given `==`/`/=` site has exactly one operand type), so
-- checking the record map first is just a fixed, arbitrary order.
toClosedEqTarget :: Hints -> A.Region -> ModuleName.Canonical -> Name.Name -> Maybe (Bool, Opt.ClosedEqShape)
toClosedEqTarget hints region home name =
  if home /= ModuleName.basics || not (name == "eq" || name == "neq") then
    Nothing
  else
    let isEq = name == "eq" in
    case Map.lookup region (_recordEqHints hints) of
      Just fields ->
        Just (isEq, Opt.ClosedEqRecord fields)

      Nothing ->
        case Map.lookup region (_unionEqHints hints) of
          Just maxArity -> Just (isEq, Opt.ClosedEqUnion maxArity)
          Nothing       -> Nothing


-- Builds the Opt.EqClosed node, registering the same runtime dependency a
-- generic Basics.eq/neq call would have needed: the Utils kernel. Dev mode
-- still falls back to _Utils_eq/_Utils_neq for these nodes (see
-- Generate.JavaScript.Expression's generateClosedEq), so the kernel chunk
-- must stay reachable even though Prod mode never calls it -- skipping
-- this the way Opt.PrimOp skips Names.registerGlobal would be wrong here,
-- since unlike PrimOp's raw `===`/`<`, EqClosed's Dev-mode codegen is
-- itself still a kernel call. For the record case, also registers the
-- field names for Prod's field-shortening table, exactly like Can.Update's
-- registerFieldList call above.
registerClosedEq :: Opt.ClosedEqShape -> Bool -> Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
registerClosedEq shape isEq optLeft optRight =
  do  withKernel <- Names.registerKernel Name.utils (Opt.EqClosed isEq shape optLeft optRight)
      case shape of
        Opt.ClosedEqRecord fields -> Names.registerFieldList (Set.toList fields) withKernel
        Opt.ClosedEqUnion _       -> pure withKernel
```

- [ ] **Step 2: Rewrite the `Can.Binop` case**

Replace:

```haskell
    Can.Binop _ home name _ left right ->
      case Map.lookup region (_primHints hints) >>= toPrimBinop home name of
        Just prim ->
          Opt.PrimOp prim
            <$> optimize hints cycle left
            <*> optimize hints cycle right

        Nothing ->
          do  optFunc <- Names.registerGlobal home name
              optLeft <- optimize hints cycle left
              optRight <- optimize hints cycle right
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
            Nothing ->
              do  optFunc <- Names.registerGlobal home name
                  optLeft <- optimize hints cycle left
                  optRight <- optimize hints cycle right
                  return (Opt.Call optFunc [optLeft, optRight])

            Just (isEq, shape) ->
              do  optLeft <- optimize hints cycle left
                  optRight <- optimize hints cycle right
                  if isCheap optLeft && isCheap optRight then
                    registerClosedEq shape isEq optLeft optRight
                  else
                    do  optFunc <- Names.registerGlobal home name
                        return (Opt.Call optFunc [optLeft, optRight])
```

(The `Nothing` branch is byte-for-byte the same code as before this task — same order of
`registerGlobal` then `optimize left` then `optimize right` — so any `==`/`/=`/`<`/`>`/`<=`/`>=`/`++`
site that isn't a closed-Record/closed-Union `==`/`/=` is entirely unaffected by this change.)

- [ ] **Step 3: Build and verify no warnings**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: clean build. The feature is now fully wired end to end.

- [ ] **Step 4: Commit**

```bash
git add compiler/src/Optimize/Expression.hs
git commit -m "feat: emit Opt.EqClosed for closed-record/closed-union ==/⁄= sites"
```

---

### Task 5: End-to-end correctness verification (real compiler, scratch project)

**Files:**
- None (no source changes) — verification only, using a scratch Elm project outside this repo.

**Interfaces:**
- Consumes: the `elm` binary built by Task 4.
- Produces: a confirmation (recorded in the commit message / session notes) that Dev output is
  byte-identical to pre-plan, and that Prod output for every positive/negative case matches the design
  spec's scope.

- [ ] **Step 1: Set up a scratch project with a fresh `ELM_HOME`**

```bash
mkdir -p /tmp/claude-1000/-home-andre-Workspace-Projects-Freinet-elm-compiler/*/scratchpad/eqclosed-verify/src
```

(Use this session's actual scratchpad path.) Create `elm.json` there with `"elm-version": "0.19.2"` and
the usual `elm/core`, `elm/json` deps (copy the shape of any prior scratch-project `elm.json` used for
earlier plans in this repo's memory, e.g. the `prim-binop-specialization` or `static-shape-record-clone`
verification runs — a minimal `elm/core`-only `elm.json` is sufficient here).

- [ ] **Step 2: Write the positive-case fixture**

Create `src/Bench.elm` (only the parts relevant to structural checks; this can be the same file used for
Task 6's benchmark, extended) covering:

```elm
module Bench exposing (main)

type alias Point = { x : Int, y : Int, label : String, active : Bool, weight : Float }

type Shape
    = Rect Int Int
    | Circle Float
    | Named String Int
    | Empty

-- Positive record case
pointEq : Point -> Point -> Bool
pointEq a b = a == b

pointNeq : Point -> Point -> Bool
pointNeq a b = a /= b

-- Positive union case (closed, non-generic, Normal ctors, same module)
shapeEq : Shape -> Shape -> Bool
shapeEq a b = a == b

-- Negative: row-polymorphic record argument, never closed at this site
widthOf : { r | x : Int } -> { r | x : Int } -> Bool
widthOf a b = a == b

-- Negative: nested record field
type alias Wrapped = { inner : Point }
wrappedEq : Wrapped -> Wrapped -> Bool
wrappedEq a b = a == b

-- Negative: List field
type alias Bag = { items : List Int }
bagEq : Bag -> Bag -> Bool
bagEq a b = a == b

-- Negative: generic union
genericEq : Maybe Int -> Maybe Int -> Bool
genericEq a b = a == b

main = Debug.toString (pointEq, pointNeq, shapeEq, widthOf, wrappedEq, bagEq, genericEq)
```

- [ ] **Step 3: Compile in Dev mode and diff against pre-plan output**

Using the Docker recipe from `CLAUDE.md`'s "Running the freshly built compiler" section, compile with
`elm make src/Bench.elm --output elm-dev.js` using the Task-4 binary. Separately, check out the commit
immediately before Task 1 (`git stash` or a second worktree), build that binary, and compile the same
`Bench.elm` to `elm-dev-before.js` with a **separate fresh `ELM_HOME`** (wire-format changed, must not
reuse a cache built by the other binary — see this plan's Global Constraints). Diff:

```bash
diff elm-dev-before.js elm-dev.js
```

Expected: **no difference** (byte-identical). If there is a difference, stop and investigate before
continuing — Dev output must never change per this plan's constraints.

- [ ] **Step 4: Compile in Prod mode and inspect the generated JS**

```bash
elm make src/Bench.elm --optimize --output elm-prod.js
```

Inspect `elm-prod.js` for:
- `pointEq`/`pointNeq` compile to a flat `a.<f>===b.<f> && ...` chain (or its negation) over exactly the
  5 `Point` fields — **not** a call to the Utils kernel's `eq`/`neq` export.
- `shapeEq` compiles to `a.$===b.$ && a.a1===b.a1 && ...` up to `Shape`'s max ctor arity (2, from
  `Rect Int Int`) — **not** a kernel call.
- `widthOf`, `wrappedEq`, `bagEq`, `genericEq` all **still** call the Utils kernel's generic equality
  function (confirms the negative/fallback cases correctly keep the generic path).

- [ ] **Step 5: Execute under Node and confirm correctness**

Write a small Node harness (`bench-runner.js`, following the `vm`-context pattern noted in
[[prim-binop-specialization-plan]]'s memory entry) that calls each of the 7 exposed functions with both
equal and unequal argument pairs and prints the results. Confirm every result matches Elm's documented
`==`/`/=` semantics (in particular: unequal `Point`s differing only in `weight` correctly report
unequal; unequal `Shape`s of different ctors, e.g. `Rect 1 2` vs `Circle 1.0`, correctly report unequal
even though both pad to the same 2-slot shape).

- [ ] **Step 6: Record the verification result**

No code changes in this task — if all checks pass, proceed to Task 6. If any check fails, return to the
relevant earlier task, fix, rebuild, and re-run this task's steps from Step 3.

---

### Task 6: Two-binary performance benchmark

**Files:**
- None (no source changes) — benchmarking only.

**Interfaces:**
- Consumes: the Task 4 binary (`after`) and the pre-Task-1 binary (`before`), both built with a fresh,
  separate `ELM_HOME`/`elm-stuff` each (per
  [[elm-stuff-cache-contamination-finding]] — never compile both variants in the same project
  directory).

- [ ] **Step 1: Reuse the Task 5 fixture at scale**

Extend `Bench.elm`'s `pointEq`/`shapeEq` fixtures to run in a tight loop over generated lists of
`Point`/`Shape` values (mirroring the spike's exact methodology: fixed target value, hot loop comparing
against it, hit-count as the checksum-bearing return value) at sizes 1,000 / 10,000 / 100,000 /
1,000,000, matching [[closed-type-structural-equality-spike]]'s original fixture shape.

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

- [ ] **Step 4: Compare against the spike's numbers**

Expected range, per the spike: record ~2.0x-2.5x, union ~2.2x-3.3x, roughly flat across the four sizes.
Record the actual measured numbers. If the real-compiler numbers diverge meaningfully from the
hand-patch spike (in either direction), investigate before declaring the feature complete — this
mirrors the discrepancy [[list-mapn-unwrapped-kernel-plan]] found between an isolated hand-spike and the
real, fully-wired compiler, which turned out to matter for the accept/reject decision.

- [ ] **Step 5: Report the result**

Summarize measured speedups for both shapes at all four sizes. This is the final task in the plan — no
further code changes are anticipated unless Task 5 or Task 6 surfaced a problem.

---

## Self-Review Notes

- **Spec coverage:** every scope item in the design spec (closed record, closed same-module non-generic
  Normal union, Prod-only codegen, `isCheap` gating, Dev-output stability, wire-format-change caveat) is
  covered by a task above (Tasks 1-4 implement it, Task 5 verifies the boundary/negative cases
  explicitly, Task 6 verifies the performance claim).
- **No placeholders:** every step above contains complete, non-elided code; no step says "add similar
  handling" without showing the actual diff.
- **Type/name consistency check:** `Hints` gains `_recordEqHints`/`_unionEqHints` in Task 2 and both are
  read only in Task 4's `toClosedEqTarget` — names match. `Opt.EqClosed`/`Opt.ClosedEqShape` are defined
  in Task 3 and constructed only in Task 4 (`registerClosedEq`) — constructor arities match (`EqClosed`
  takes `Bool -> ClosedEqShape -> Expr -> Expr`, called as `Opt.EqClosed isEq shape optLeft optRight` in
  Task 4's `registerClosedEq`, matching Task 3's definition and Binary instance argument order). `Type.run`'s
  new arity (3 args: `home`, `unions`, `constraint`) matches its Task 2 Step 4 call site in `Compile.hs`.
