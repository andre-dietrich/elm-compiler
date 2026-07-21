{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Optimize.Expression
  ( optimize
  , Hints(..)
  , destructArgs
  , optimizePotentialTailCall
  , collectApplication
  )
  where


import Prelude hiding (cycle)
import Control.Monad (foldM)
import qualified Data.Map as Map
import qualified Data.Name as Name
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Optimized as Opt
import qualified AST.Utils.Shader as Shader
import qualified AST.Utils.Type as CanType
import qualified Data.Index as Index
import qualified Elm.ModuleName as ModuleName
import qualified Generate.JavaScript.Name as JsName
import qualified Optimize.Case as Case
import qualified Optimize.Names as Names
import qualified Optimize.Port as Port
import qualified Reporting.Annotation as A
import qualified Type.Type as Type



-- OPTIMIZE


type Cycle =
  Set.Set Name.Name


-- Bundles two whole-module-derived lookup tables threaded down through
-- every optimize call:
--
-- _primHints: resolved primitive type of comparison/append Binop call
-- sites, keyed by the Binop's region. Populated by Type.Solve from CProbe
-- constraints; see Type.Type's PrimType. Absent entries mean "not proven
-- monomorphic", keeping the generic Basics.eq/append call.
--
-- _annotations: every top-level def's inferred type in this module, keyed
-- by name. Needed by the Worker.run call-site rewrite (buildWorkerRun,
-- below) to resolve a `Can.VarTopLevel` fn argument's encoder/decoder
-- types -- unlike Can.VarForeign, VarTopLevel carries no Annotation of its
-- own (see AST.Canonical's Expr_). Bundled into Hints instead of threaded
-- as a separate parameter to avoid touching every optimize/addRecDef*
-- signature in Optimize.Module.
data Hints =
  Hints
    { _primHints :: Map.Map A.Region Type.PrimType
    , _annotations :: Map.Map Name.Name Can.Annotation
    }


optimize :: Hints -> Cycle -> Can.Expr -> Names.Tracker Opt.Expr
optimize hints cycle (A.At region expression) =
  case expression of
    -- LIST PIPELINE FUSION trigger. Must be a wildcard-guarded alternative
    -- (not `Can.Call func args | ...`) because the shape this recognizes
    -- -- a saturated call to `List.foldl` -- can now arrive either as an
    -- ordinary Can.Call *or* as a Can.Binop chain of `|>`/`<|` (Basics
    -- apR/apL), which `collectApplication` normalizes to the same
    -- (callee, args) shape. A single case alternative can only pattern-match
    -- one constructor, so this has to sit on `_` and fall through via guard
    -- failure -- exactly like the narrower `Can.Call func args | ...`
    -- alternative it replaces -- to every other expression shape, including
    -- plain `Can.Call` (handled by the next alternative below) and ordinary
    -- `Can.Binop` (handled further down). See
    -- docs/superpowers/specs/2026-07-18-list-foldl-map-filter-fusion-design.md,
    -- "Correction (post-Task-1-review)", for why this moved here.
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

      -- WORKER.RUN call-site rewrite. Requires at least one argument
      -- (fnArg : dataArgs) so a bare, unapplied `Worker.run` falls through
      -- to the plain Can.VarForeign case further below instead (compiled
      -- as an ordinary, never-actually-called global reference -- Nitpick
      -- .Worker already rejects that shape as a compile error before this
      -- pass ever runs, so reaching here with zero args should not happen
      -- for a program that passed Nitpick). See buildWorkerRun.
      | (A.At _ (Can.VarForeign home name _), fnArg : dataArgs) <- collectApplication (A.At region expression)
      , home == ModuleName.worker, name == "run"
      ->
          buildWorkerRun hints cycle fnArg dataArgs

      -- BARE PRODUCER-CHAIN FUSION trigger (no terminator). Must come
      -- after all four terminator guards above: if this expression is
      -- itself a call to foldl/sum/product/length, one of those guards
      -- already matched and this line is never reached (Haskell tries
      -- guards top-to-bottom, first match wins). Does NOT call
      -- collectApplication/match on Can.VarForeign at all -- unlike the
      -- terminator guards, it doesn't need to identify what function
      -- this expression is a call to, because there isn't one to check:
      -- it directly peelChains the whole expression being optimized.
      | (stages@(_:_:_), source) <- peelChain (A.At region expression)
      ->
          buildFusedHelper hints cycle stages source

    Can.VarLocal name ->
      pure (Opt.VarLocal name)

    Can.VarTopLevel home name ->
      if Set.member name cycle then
        pure (Opt.VarCycle home name)
      else
        Names.registerGlobal home name

    Can.VarKernel home name ->
      Names.registerKernel home (Opt.VarKernel home name)

    Can.VarForeign home name _ ->
      Names.registerGlobal home name

    Can.VarCtor opts home name index _ ->
      Names.registerCtor home name index opts

    Can.VarDebug home name _ ->
      Names.registerDebug name home region

    Can.VarOperator _ home name _ ->
      Names.registerGlobal home name

    Can.Chr chr ->
      Names.registerKernel Name.utils (Opt.Chr chr)

    Can.Str str ->
      pure (Opt.Str str)

    Can.Int int ->
      pure (Opt.Int int)

    Can.Float float ->
      pure (Opt.Float float)

    Can.List entries ->
      Names.registerKernel Name.list Opt.List
        <*> traverse (optimize hints cycle) entries

    Can.Negate expr ->
      do  func <- Names.registerGlobal ModuleName.basics Name.negate
          arg <- optimize hints cycle expr
          pure $ Opt.Call func [arg]

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

    Can.Lambda args body ->
      do  (argNames, destructors) <- destructArgs args
          obody <- optimize hints cycle body
          pure $ Opt.Function argNames (foldr Opt.Destruct obody destructors)

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

    Can.If branches finally ->
      let
        optimizeBranch (condition, branch) =
          (,)
            <$> optimize hints cycle condition
            <*> optimize hints cycle branch
      in
      Opt.If
        <$> traverse optimizeBranch branches
        <*> optimize hints cycle finally

    Can.Let def body ->
      optimizeDef hints cycle def =<< optimize hints cycle body

    Can.LetRec defs body ->
      case defs of
        [def] ->
          Opt.Let
            <$> optimizePotentialTailCallDef hints cycle def
            <*> optimize hints cycle body

        _ ->
          do  obody <- optimize hints cycle body
              foldM (\bod def -> optimizeDef hints cycle def bod) obody defs

    Can.LetDestruct pattern expr body ->
      do  (name, destructs) <- destruct pattern
          oexpr <- optimize hints cycle expr
          obody <- optimize hints cycle body
          pure $
            Opt.Let (Opt.Def name oexpr) (foldr Opt.Destruct obody destructs)

    Can.Case expr branches ->
      let
        optimizeBranch root (Can.CaseBranch pattern branch) =
          do  destructors <- destructCase root pattern
              obranch <- optimize hints cycle branch
              pure (pattern, foldr Opt.Destruct obranch destructors)
      in
      do  temp <- Names.generate
          oexpr <- optimize hints cycle expr
          case oexpr of
            Opt.VarLocal root ->
              Case.optimize temp root <$> traverse (optimizeBranch root) branches

            _ ->
              do  obranches <- traverse (optimizeBranch temp) branches
                  return $ Opt.Let (Opt.Def temp oexpr) (Case.optimize temp temp obranches)

    Can.Accessor field ->
      Names.registerField field (Opt.Accessor field)

    Can.Access record (A.At _ field) ->
      do  optRecord <- optimize hints cycle record
          Names.registerField field (Opt.Access optRecord field)

    Can.Update _ record updates ->
      Names.registerFieldDict updates Opt.Update
        <*> optimize hints cycle record
        <*> traverse (optimizeUpdate hints cycle) updates

    Can.Record fields ->
      Names.registerFieldDict fields Opt.Record
        <*> traverse (optimize hints cycle) fields

    Can.Unit ->
      Names.registerKernel Name.utils Opt.Unit

    Can.Tuple a b maybeC ->
      Opt.Tuple
        <$> optimize hints cycle a
        <*> optimize hints cycle b
        <*> traverse (optimize hints cycle) maybeC

    Can.Shader src (Shader.Types attributes uniforms _varyings) ->
      pure (Opt.Shader src (Map.keysSet attributes) (Map.keysSet uniforms))



-- PRIM BINOP


-- Only Basics operators can be specialized (custom infix operators do not
-- exist in Elm 0.19+, so "==","/=","<",">","<=",">=","++" always resolve
-- here). Comparisons accept any proven PrimType; append only accepts PStr
-- (List append keeps calling _Utils_ap either way).
toPrimBinop :: ModuleName.Canonical -> Name.Name -> Type.PrimType -> Maybe Opt.PrimBinop
toPrimBinop home name prim =
  if home /= ModuleName.basics then
    Nothing
  else
    case name of
      "eq"     -> Just Opt.PrimEq
      "neq"    -> Just Opt.PrimNeq
      "lt"     -> Just Opt.PrimLt
      "gt"     -> Just Opt.PrimGt
      "le"     -> Just Opt.PrimLe
      "ge"     -> Just Opt.PrimGe
      "append" -> if prim == Type.PStr then Just Opt.PrimAppend else Nothing
      _        -> Nothing



-- PRIM CALL


-- Saturated calls to Basics.compare/min/max whose argument type was proven
-- JS-primitive-safe (see Type.Constrain.Expression's primCallProbe). They
-- inline to raw JS comparisons, but only when both arguments are cheap to
-- re-evaluate, since the operands appear twice in the inlined form.
data PrimCall
  = CallCompare
  | CallMin
  | CallMax


toPrimCall :: Hints -> A.Region -> Can.Expr -> [Can.Expr] -> Maybe PrimCall
toPrimCall hints region (A.At _ func) args =
  case (func, args) of
    (Can.VarForeign home name _, [_, _]) | home == ModuleName.basics ->
      case Map.lookup region (_primHints hints) of
        Nothing ->
          Nothing

        Just _ ->
          case name of
            "compare" -> Just CallCompare
            "min"     -> Just CallMin
            "max"     -> Just CallMax
            _         -> Nothing

    _ ->
      Nothing


-- Pure expressions whose duplication neither repeats work nor grows the
-- output noticeably. Anything else keeps the generic Basics call.
isCheap :: Opt.Expr -> Bool
isCheap expr =
  case expr of
    Opt.VarLocal _    -> True
    Opt.VarGlobal _   -> True
    Opt.VarEnum _ _   -> True
    Opt.Bool _        -> True
    Opt.Int _         -> True
    Opt.Float _       -> True
    Opt.Str _         -> True
    Opt.Access e _    -> isCheap e
    _                 -> False


-- `min a b` becomes `if a < b then a else b` (and analogously for max),
-- which Generate.JavaScript emits as a raw ternary. `compare a b` becomes
-- the LT/EQ/GT chain, so the Order constructors must be registered as
-- dependencies here.
makePrimCall :: PrimCall -> Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
makePrimCall spec left right =
  case spec of
    CallMin ->
      pure $ Opt.If [(Opt.PrimOp Opt.PrimLt left right, left)] right

    CallMax ->
      pure $ Opt.If [(Opt.PrimOp Opt.PrimGt left right, left)] right

    CallCompare ->
      do  lt <- Names.registerCtor ModuleName.basics "LT" Index.first Can.Enum
          eq <- Names.registerCtor ModuleName.basics "EQ" Index.second Can.Enum
          gt <- Names.registerCtor ModuleName.basics "GT" Index.third Can.Enum
          pure $ Opt.If
            [ (Opt.PrimOp Opt.PrimLt left right, lt)
            , (Opt.PrimOp Opt.PrimEq left right, eq)
            ]
            gt



-- WORKER.RUN
--
-- Rewrites a validated `Worker.run fn ...` call -- Nitpick.Worker has
-- already confirmed `fn` is a bare top-level/foreign reference with
-- port-safe domain/codomain types, not part of a same-module recursive
-- group -- into a kernel call carrying a stable dispatch tag plus a
-- synthesized encoder/decoder pair, reusing Optimize.Port's port payload
-- codecs directly (same restricted type set, same machinery). `fn` is still
-- optimized through the ordinary Names.registerGlobal path (not replaced by
-- a bare string), so normal reachability/dead-code-elimination keeps
-- rooting it exactly like any other referenced global.
--
-- Embeds FOUR codecs, not two: `encodeArg`/`decodeResult` are what the
-- calling (main-thread) side needs to send `data` out and interpret the
-- reply; `decodeArg`/`encodeResult` are the mirror-image pair the *worker*
-- side needs (decode the incoming payload back into an `a` to feed `fn`,
-- then encode `fn`'s `b` result to send back) -- Nitpick.WorkerRegistry's
-- whole-program scan pulls those two back out of this same call node to
-- build the `_Worker_register(tag, decodeArg, encodeResult, fn)` statement
-- (see Generate.JavaScript's registerStmt), so the worker-side dispatcher
-- has codecs of its own rather than only the main-thread's pair. Embedding
-- all four in one call node (rather than only the two `_Worker_run` itself
-- reads at runtime) is also what makes decodeArg/encodeResult's own
-- dependencies (e.g. Json.Decode.int) get tracked as reachable at all --
-- Names.Tracker records every registerGlobal/registerCtor call made while
-- building this expression, regardless of which arguments the kernel
-- function actually reads.
buildWorkerRun :: Hints -> Cycle -> Can.Expr -> [Can.Expr] -> Names.Tracker Opt.Expr
buildWorkerRun hints cycle fnArg dataArgs =
  do  let (fnHome, fnName, fnType) = resolveFnRef hints fnArg
      let (argType, resultType) =
            case CanType.delambda (CanType.deepDealias fnType) of
              [a, b] -> (a, b)
              _      -> error "buildWorkerRun: fn must be a plain unary function; Nitpick.Worker should have rejected this"
      encodeArg    <- Port.toEncoder argType
      decodeResult <- Port.toDecoder resultType
      decodeArg    <- Port.toDecoder argType
      encodeResult <- Port.toEncoder resultType
      fnGlobal     <- Names.registerGlobal fnHome fnName
      workerRun    <- Names.registerKernel Name.worker (Opt.VarKernel Name.worker "run")
      let tag = Opt.Str (JsName.workerTag fnHome fnName)
      let run1 = Opt.Call workerRun [tag, encodeArg, decodeResult, decodeArg, encodeResult, fnGlobal]
      case dataArgs of
        [] ->
          pure run1

        _ ->
          do  optData <- traverse (optimize hints cycle) dataArgs
              pure (Opt.Call run1 optData)


-- fn is guaranteed to be a bare Can.VarTopLevel/Can.VarForeign reference by
-- Nitpick.Worker; VarForeign carries its own Annotation, VarTopLevel needs
-- the same-module `_annotations` lookup Hints carries for exactly this
-- purpose (see Hints's own comment above).
resolveFnRef :: Hints -> Can.Expr -> (ModuleName.Canonical, Name.Name, Can.Type)
resolveFnRef hints (A.At _ expr) =
  case expr of
    Can.VarTopLevel home name ->
      case Map.lookup name (_annotations hints) of
        Just (Can.Forall _ tipe) -> (home, name, tipe)
        Nothing -> error "buildWorkerRun: missing annotation for a validated Worker.run target"

    Can.VarForeign home name (Can.Forall _ tipe) ->
      (home, name, tipe)

    _ ->
      error "buildWorkerRun: fn is not a bare top-level reference; Nitpick.Worker should have rejected this"



-- UPDATE


optimizeUpdate :: Hints -> Cycle -> Can.FieldUpdate -> Names.Tracker Opt.Expr
optimizeUpdate hints cycle (Can.FieldUpdate _ expr) =
  optimize hints cycle expr



-- DEFINITION


optimizeDef :: Hints -> Cycle -> Can.Def -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDef hints cycle def body =
  case def of
    Can.Def (A.At _ name) args expr ->
      optimizeDefHelp hints cycle name args expr body

    Can.TypedDef (A.At _ name) _ typedArgs expr _ ->
      optimizeDefHelp hints cycle name (map fst typedArgs) expr body


optimizeDefHelp :: Hints -> Cycle -> Name.Name -> [Can.Pattern] -> Can.Expr -> Opt.Expr -> Names.Tracker Opt.Expr
optimizeDefHelp hints cycle name args expr body =
  do  oexpr <- optimize hints cycle expr
      case args of
        [] ->
          pure $ Opt.Let (Opt.Def name oexpr) body

        _ ->
          do  (argNames, destructors) <- destructArgs args
              let ofunc = Opt.Function argNames (foldr Opt.Destruct oexpr destructors)
              pure $ Opt.Let (Opt.Def name ofunc) body



-- DESTRUCTURING


destructArgs :: [Can.Pattern] -> Names.Tracker ([Name.Name], [Opt.Destructor])
destructArgs args =
  do  (argNames, destructorLists) <- unzip <$> traverse destruct args
      return (argNames, concat destructorLists)


destructCase :: Name.Name -> Can.Pattern -> Names.Tracker [Opt.Destructor]
destructCase rootName pattern =
  reverse <$> destructHelp (Opt.Root rootName) pattern []


destruct :: Can.Pattern -> Names.Tracker (Name.Name, [Opt.Destructor])
destruct pattern@(A.At _ ptrn) =
  case ptrn of
    Can.PVar name ->
      pure (name, [])

    Can.PAlias subPattern name ->
      do  revDs <- destructHelp (Opt.Root name) subPattern []
          pure (name, reverse revDs)

    _ ->
      do  name <- Names.generate
          revDs <- destructHelp (Opt.Root name) pattern []
          pure (name, reverse revDs)


destructHelp :: Opt.Path -> Can.Pattern -> [Opt.Destructor] -> Names.Tracker [Opt.Destructor]
destructHelp path (A.At region pattern) revDs =
  case pattern of
    Can.PAnything ->
      pure revDs

    Can.PVar name ->
      pure (Opt.Destructor name path : revDs)

    Can.PRecord fields ->
      let
        toDestruct name =
          Opt.Destructor name (Opt.Field name path)
      in
      Names.registerFieldList fields (map toDestruct fields ++ revDs)

    Can.PAlias subPattern name ->
      destructHelp (Opt.Root name) subPattern $
        Opt.Destructor name path : revDs

    Can.PUnit ->
      pure revDs

    Can.PTuple a b Nothing ->
      destructTwo path a b revDs

    Can.PTuple a b (Just c) ->
      case path of
        Opt.Root _ ->
          destructHelp (Opt.Index Index.third path) c =<<
            destructHelp (Opt.Index Index.second path) b =<<
              destructHelp (Opt.Index Index.first path) a revDs

        _ ->
          do  name <- Names.generate
              let newRoot = Opt.Root name
              destructHelp (Opt.Index Index.third newRoot) c =<<
                destructHelp (Opt.Index Index.second newRoot) b =<<
                  destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path : revDs)

    Can.PList [] ->
      pure revDs

    Can.PList (hd:tl) ->
      destructTwo path hd (A.At region (Can.PList tl)) revDs

    Can.PCons hd tl ->
      destructTwo path hd tl revDs

    Can.PChr _ ->
      pure revDs

    Can.PStr _ ->
      pure revDs

    Can.PInt _ ->
      pure revDs

    Can.PBool _ _ ->
      pure revDs

    Can.PCtor _ _ (Can.Union _ _ _ opts) _ _ args ->
      case args of
        [Can.PatternCtorArg _ _ arg] ->
          case opts of
            Can.Normal -> destructHelp (Opt.Index Index.first path) arg revDs
            Can.Unbox  -> destructHelp (Opt.Unbox path) arg revDs
            Can.Enum   -> destructHelp (Opt.Index Index.first path) arg revDs

        _ ->
          case path of
            Opt.Root _ ->
              foldM (destructCtorArg path) revDs args

            _ ->
              do  name <- Names.generate
                  foldM (destructCtorArg (Opt.Root name)) (Opt.Destructor name path : revDs) args


destructTwo :: Opt.Path -> Can.Pattern -> Can.Pattern -> [Opt.Destructor] -> Names.Tracker [Opt.Destructor]
destructTwo path a b revDs =
  case path of
    Opt.Root _ ->
      destructHelp (Opt.Index Index.second path) b =<<
        destructHelp (Opt.Index Index.first path) a revDs

    _ ->
      do  name <- Names.generate
          let newRoot = Opt.Root name
          destructHelp (Opt.Index Index.second newRoot) b =<<
            destructHelp (Opt.Index Index.first newRoot) a (Opt.Destructor name path : revDs)


destructCtorArg :: Opt.Path -> [Opt.Destructor] -> Can.PatternCtorArg -> Names.Tracker [Opt.Destructor]
destructCtorArg path revDs (Can.PatternCtorArg index _ arg) =
  destructHelp (Opt.Index index path) arg revDs



-- TAIL RECURSION MODULO CONS
--
-- `f x :: recurse rest` (Kernel List `::` whose right operand is a
-- saturated self-call, in tail position) compiles to a loop that builds
-- the result list top-down and fills a "hole" via mutation, instead of a
-- non-tail recursive call whose stack depth is bounded by input length.
-- See memory/trmc-plan.md for the design and Schritt-0 benchmark data.
--
-- V1 scope: only the Kernel `List.cons` constructor (2 fields, hole is
-- the tail/second field), and only a direct self-call as the right
-- operand (no further nesting through If/Case on that side). Branches
-- that are a bare self-call with no `::` wrapper (Opt.TailCall) may
-- coexist with TailCallCons branches in the same function: they simply
-- continue the loop without opening a new cell.


isListCons :: ModuleName.Canonical -> Name.Name -> Bool
isListCons home name =
  home == ModuleName.list && name == "cons"


-- LIST PIPELINE FUSION (map/filter -> foldl)
--
-- See docs/superpowers/specs/2026-07-18-list-foldl-map-filter-fusion-design.md
-- for the full derivation and correctness argument. Summary: `List.foldl
-- step acc (List.map f (List.filter p xs))`-shaped pipelines currently
-- compile to one full traversal+allocation per producer stage. This peels
-- map/filter layers off a List.foldl's list argument and, when at least
-- one layer is found, synthesizes a single composed step function so the
-- whole pipeline becomes one List.foldl call with zero intermediate lists.


-- One layer of a producer chain. Carries the *unoptimized* Can.Expr for
-- the function/predicate so it gets `optimize`'d in the right place
-- (inside the synthesized step, not hoisted out of its original scope).
data ListStage
  = StageMap Can.Expr Can.Expr        -- f, inner list expr
  | StageFilter Can.Expr Can.Expr     -- p, inner list expr
  | StageFilterMap Can.Expr Can.Expr  -- f, inner list expr


-- Normalizes an application shape into (callee, fully-gathered args),
-- treating ordinary Can.Call *and* `|>`/`<|` (Basics.apR/apL) uniformly.
-- Idiomatic Elm pipelines desugar to Can.Binop, not Can.Call -- only
-- Generate.JavaScript.Expression's `apply` flattens that into a single
-- call, and that runs in the Generate phase, strictly after
-- Optimize.Expression (where this fusion pass lives) has already finished.
-- This mirrors that same flattening one phase earlier, on Can.Expr, so
-- peelListStage/the foldl trigger below can recognize a List.foldl/map/
-- filter call site regardless of whether the source wrote it as ordinary
-- application (`List.foldl step acc xs`) or a pipe
-- (`xs |> List.foldl step acc`). Recursing into the callee side keeps
-- chained pipes (`xs |> List.filter p |> List.map f`) flattening all the
-- way down.
collectApplication :: Can.Expr -> (Can.Expr, [Can.Expr])
collectApplication expr@(A.At _ expression) =
  case expression of
    Can.Call func args ->
      (func, args)

    Can.Binop _ home name _ left right
      | home == ModuleName.basics, name == "apR" ->
          let (callee, args) = collectApplication right in (callee, args ++ [left])
      | home == ModuleName.basics, name == "apL" ->
          let (callee, args) = collectApplication left in (callee, args ++ [right])

    _ ->
      (expr, [])


-- Nothing => not a recognized producer shape (the true source list, or a
-- fusion barrier this pass doesn't understand, e.g. sortBy/take) =>
-- stop peeling here. Only elm/core's own List.map/List.filter/List.filterMap match;
-- everything else (including a local `myMap = List.map` alias) falls
-- through untouched.
peelListStage :: Can.Expr -> Maybe ListStage
peelListStage expr =
  case collectApplication expr of
    (A.At _ (Can.VarForeign home name _), [f, inner])
      | home == ModuleName.list, name == "map" ->
          Just (StageMap f inner)
      | home == ModuleName.list, name == "filter" ->
          Just (StageFilter f inner)
      | home == ModuleName.list, name == "filterMap" ->
          Just (StageFilterMap f inner)
    _ ->
      Nothing


stageInner :: ListStage -> Can.Expr
stageInner (StageMap _ inner)       = inner
stageInner (StageFilter _ inner)    = inner
stageInner (StageFilterMap _ inner) = inner


-- Peels as many layers as match, outermost (closest to the foldl) first.
-- Returns the peeled stages plus whatever expression peeling stopped at.
peelChain :: Can.Expr -> ([ListStage], Can.Expr)
peelChain expr =
  case peelListStage expr of
    Nothing    -> ([], expr)
    Just stage -> let (rest, source) = peelChain (stageInner stage) in (stage : rest, source)


-- A step continuation: given the current raw element and the current
-- accumulator (already-`optimize`'d Opt.Expr), produces the new
-- accumulator. `foldM` over `stages` left-to-right (outermost stage
-- wrapped first) reconstructs the original evaluation order: a filter's
-- predicate is checked on the *original* element before any outer map's
-- transform is applied, exactly as `filter p xs |> map f` implies.
type StepK = Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr


baseStepK :: Opt.Expr -> StepK
baseStepK optStep elemExpr accExpr =
  pure (Opt.Call optStep [elemExpr, accExpr])


-- Synthesized Maybe union info + Just/Nothing patterns, used to fuse
-- filterMap's Maybe-producing function via the existing pattern-match
-- compiler (Optimize.Case/Optimize.DecisionTree) instead of hand-rolling a
-- ctor-tag test whose Dev/Prod representation this pass would otherwise
-- have to track itself. The Can.TVar "a" type placeholders are inert:
-- destructHelp's single-arg PCtor case (Just, here) and destructCtorArg's
-- multi-arg case (unreached by Just/Nothing, but the same discard) both
-- throw away PatternCtorArg's type field with `_`, and DecisionTree.
-- testAtPath discards Can.Union's _u_vars with `_` — nothing past
-- canonicalization reads either, confirmed by reading all three sites.
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


-- Shared tail of every fusion trigger below (foldl/sum/product/length):
-- given a base step continuation and an initial accumulator value already
-- as Opt.Expr, peels/composes `stages` over `source` and emits one
-- ordinary List.foldl call. `initExpr` is the terminator's implicit init
-- as a literal Opt.Int -- 0 for sum/length, 1 for product -- or the
-- user's own already-`optimize`'d acc argument for foldl.
--
-- Caveat for `length` specifically: baseStepKLength (below) ignores its
-- element-expression argument via `_`, so when a StageMap sits directly
-- in front of a `length` terminator, the `Opt.Call optF [elemExpr]`
-- wrapStage's StageMap case builds for that map is never referenced by
-- the composed step and is dropped before any Opt.Expr tree is even
-- returned -- unlike V1's foldl fusion, where a StepK's element argument
-- always ends up threaded into the emitted step call, this makes the
-- generated code for `xs |> List.map f |> List.length` never call `f` at
-- all. Unobservable for a total, effect-free `f` (all this pass's other
-- correctness claims assume that class of function too), but a real
-- behavioral difference from the unfused baseline if `f` diverges,
-- crashes, or (Dev builds) calls Debug.log -- those would fire on every
-- unfused element and fire zero times fused. Deliberately accepted
-- (see docs/superpowers/specs/2026-07-19-list-fusion-v2-design.md's
-- "Why this is semantics-preserving" section), not a bug: `List.length`
-- is defined not to depend on the mapped values at all.
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


-- BARE PRODUCER-CHAIN FUSION (map/filter/filterMap, no terminator)
--
-- See docs/superpowers/specs/2026-07-19-bare-producer-chain-fusion-design.md
-- for the full derivation and correctness argument. Summary: a producer
-- chain with no recognized terminator (foldl/sum/product/length) --
-- e.g. `Html.ul [] (List.map viewItem items)` -- is untouched by V1/V2,
-- since those only rewrite a *terminator's* list argument. This
-- synthesizes the Can.Expr a hand-written local recursive helper
-- (`let helper xs = case xs of [] -> []; x :: rest -> ... in helper
-- source`) would produce, and feeds it through optimizePotentialTailCall
-- -- the same entry point a real user-written local recursive `let`
-- already goes through -- so TRMC's existing sentinel/mutation codegen
-- compiles it to a single-pass, stack-safe loop for free.


-- `Can.Annotation`'s type-inference cache is dead weight past
-- canonicalization for every use in this pass (mirrors the Can.TVar "a"
-- placeholders already used for Maybe's synthesized patterns above).
inertAnnotation :: Can.Annotation
inertAnnotation =
  Can.Forall Map.empty (Can.TVar "a")


-- `::` as an *expression* is sugar for a Can.Binop on elm/core's
-- `List.cons`, not Can.Call+VarCtor (see isListCons's comment above) --
-- this is the exact shape optimizeTail's `Can.Binop _ home name _ left
-- right | isListCons home name` branch recognizes as a TRMC candidate.
-- The opSymbol/Annotation fields are pattern-matched as `_` at every
-- existing call site in this file, confirming they're dead for this
-- phase.
consExpr :: Can.Expr -> Can.Expr -> Can.Expr
consExpr headExpr tailExpr =
  A.At A.zero (Can.Binop "::" ModuleName.list "cons" inertAnnotation headExpr tailExpr)


-- List's `[]`/`::` patterns are dedicated Can.Pattern_ constructors
-- (PList/PCons), not PCtor-based like Maybe -- no synthesized
-- Union/Ctor info needed at all.
pNil :: Can.Pattern
pNil =
  A.At A.zero (Can.PList [])


pConsHead :: Name.Name -> Name.Name -> Can.Pattern
pConsHead headName tailName =
  A.At A.zero $
    Can.PCons
      (A.At A.zero (Can.PVar headName))
      (A.At A.zero (Can.PVar tailName))


-- Can-level analogue of StepK: given the Can.Expr for "the current
-- element at this point in the composed pipeline" (initially the raw
-- Can.VarLocal bound by the outer PCons pattern; after a
-- StageMap/StageFilterMap, a fresh reference to that stage's result),
-- produces the Can.Expr for what happens to it. Threads Names.Tracker
-- throughout (unlike StepK, which only needs it at its own two call
-- sites) because StageFilterMap must Names.generate a fresh Just-binder
-- name once per stage *occurrence* -- a compile-time AST-construction
-- step, not something that happens once per element at runtime.
type StepC = Can.Expr -> Names.Tracker Can.Expr


-- The fixed recursive step every chain bottoms out at: `elemExpr ::
-- helper rest`.
baseStepC :: Can.Expr -> StepC
baseStepC recurseExpr elemExpr =
  pure (consExpr elemExpr recurseExpr)


-- The fixed "skip this element" action every Filter/FilterMap failure
-- bottoms out at: bare `helper rest`, no new cell.
skipExpr :: Can.Expr -> Can.Expr
skipExpr recurseExpr =
  recurseExpr


-- No Hints/Cycle parameters (unlike wrapStage): those exist there only
-- to recursively `optimize` a stage's f/p *now*, producing Opt.Expr.
-- Here f/p stay as unoptimized Can.Expr splices, only reaching
-- `optimize` later, inside optimizePotentialTailCall's own traversal.
wrapStageC :: Can.Expr -> StepC -> ListStage -> Names.Tracker StepC
wrapStageC recurseExpr inner stage =
  case stage of
    StageMap f _ ->
      -- No memoization: `f elemExpr` is textually re-embedded at each
      -- use `inner` makes of its argument, matching wrapStage's own
      -- StageFilter precedent (a following StageFilter/StageFilterMap
      -- checks it once and forwards it once) -- inherited, not a new
      -- limitation; see the design spec's "Still out of scope".
      pure $ \elemExpr -> inner (A.At A.zero (Can.Call f [elemExpr]))

    StageFilter p _ ->
      pure $ \elemExpr ->
        do  thenBranch <- inner elemExpr
            pure $ A.At A.zero (Can.If [(A.At A.zero (Can.Call p [elemExpr]), thenBranch)] (skipExpr recurseExpr))

    StageFilterMap f _ ->
      -- Case-bound, so naturally memoized -- reuses pJust/pNothing/
      -- maybeUnion verbatim, since they're already Can-level pattern
      -- builders (defined above by V2), not Opt-level.
      pure $ \elemExpr ->
        do  yName      <- Names.generate
            thenBranch <- inner (A.At A.zero (Can.VarLocal yName))
            pure $ A.At A.zero $
              Can.Case (A.At A.zero (Can.Call f [elemExpr]))
                [ Can.CaseBranch (pJust yName) thenBranch
                , Can.CaseBranch pNothing (skipExpr recurseExpr)
                ]


-- Top-level assembly: synthesizes `let helper xs = case xs of [] -> [];
-- x :: rest -> <composed stages> in helper source` and hands the
-- def-shaped body to optimizePotentialTailCall, which detects the TRMC
-- shape and returns an Opt.TailDefCons (mixed with plain Opt.TailCall
-- for the "skip" branches) -- the identical Opt.Def a real user-written
-- local recursive helper of this exact shape would already produce.
buildFusedHelper :: Hints -> Cycle -> [ListStage] -> Can.Expr -> Names.Tracker Opt.Expr
buildFusedHelper hints cycle stages source =
  do  helperName <- Names.generate
      paramName  <- Names.generate
      xName      <- Names.generate
      restName   <- Names.generate
      let recurseExpr = A.At A.zero (Can.Call (A.At A.zero (Can.VarLocal helperName)) [A.At A.zero (Can.VarLocal restName)])
      composed  <- foldM (wrapStageC recurseExpr) (baseStepC recurseExpr) stages
      consBody  <- composed (A.At A.zero (Can.VarLocal xName))
      let body = A.At A.zero $ Can.Case (A.At A.zero (Can.VarLocal paramName))
                   [ Can.CaseBranch pNil (A.At A.zero (Can.List []))
                   , Can.CaseBranch (pConsHead xName restName) consBody
                   ]
      helperDef <- optimizePotentialTailCall hints cycle helperName [A.At A.zero (Can.PVar paramName)] body
      optSource <- optimize hints cycle source
      pure $ Opt.Let helperDef (Opt.Call (Opt.VarLocal helperName) [optSource])


-- Does this list of arguments contain exactly one direct self-call (a
-- saturated Can.Call to rootName, no further nesting through If/Case)?
-- If so, at which (rightmost) position? A pure syntactic check -- no
-- optimization, no Names.Tracker effects -- shared between the
-- detectConsIdentity pre-scan and optimizeTail's real construction of
-- the hole argument's rebind pairs.
findHoleIndex :: Name.Name -> [Name.Name] -> [Can.Expr] -> Maybe Index.ZeroBased
findHoleIndex rootName argNames args =
  case [ i | (i, arg) <- Index.indexedMap (,) args, isDirectSelfCall rootName argNames arg ] of
    [] -> Nothing
    is -> Just (last is)


-- Every argument except the one at holeIndex, paired with its original
-- position -- these become a TailCallCons node's non-hole fields.
otherIndexedArgs :: Index.ZeroBased -> [Can.Expr] -> [(Index.ZeroBased, Can.Expr)]
otherIndexedArgs holeIndex args =
  filter ((/= holeIndex) . fst) (Index.indexedMap (,) args)


isDirectSelfCall :: Name.Name -> [Name.Name] -> Can.Expr -> Bool
isDirectSelfCall rootName argNames (A.At _ expression) =
  case expression of
    Can.Call func args ->
      let
        isMatchingName =
          case A.toValue func of
            Can.VarLocal      name -> rootName == name
            Can.VarTopLevel _ name -> rootName == name
            _                      -> False
      in
      isMatchingName && length args == length argNames

    _ ->
      False


allSame :: Eq a => [a] -> Maybe a
allSame list =
  case list of
    []     -> Nothing
    x : xs -> if all (== x) xs then Just x else Nothing


-- Pure pre-pass over the *unoptimized* Can.Expr, mirroring optimizeTail's
-- own tail-position structural traversal but building nothing. Collects
-- every candidate (ConsInfo, hole field index) reachable in tail
-- position; returns Just identity only if exactly one distinct candidate
-- exists (Nothing if none are found, or if more than one disagree -- see
-- docs/superpowers/specs/2026-07-03-trmc-general-adt-ctors-design.md).
detectConsIdentity :: Name.Name -> [Name.Name] -> Can.Expr -> Maybe (Opt.ConsInfo, Index.ZeroBased)
detectConsIdentity rootName argNames expr =
  allSame (collectConsCandidates rootName argNames expr)


collectConsCandidates :: Name.Name -> [Name.Name] -> Can.Expr -> [(Opt.ConsInfo, Index.ZeroBased)]
collectConsCandidates rootName argNames (A.At _ expression) =
  case expression of
    Can.Binop _ home name _ _ right | isListCons home name ->
      case findHoleIndex rootName argNames [right] of
        Just _  -> [(Opt.ConsKernel, Index.second)]
        Nothing -> []

    -- Constructors of arity 2..9 are F2..F9-wrapped in the generated JS
    -- (Generate.Mode's restrictRange / Generate.JavaScript.Expression's
    -- funcHelpers both cap at 9), so generateConsCell's `.f`-bypass call
    -- is valid for them. Arity 10+ is never F-wrapped -- it's nested
    -- curried unary functions with no direct N-ary entry point at all --
    -- so disqualify those from TRMC entirely here, at the source, rather
    -- than trying to make codegen handle the nested-unary shape: this
    -- keeps consIdentity's detection guarantee ("every ConsCtor identity
    -- this can ever produce is safe for generateConsCell to construct")
    -- intact without touching codegen.
    Can.Call (A.At _ (Can.VarCtor Can.Normal home name _ _)) args | length args <= 9 ->
      case findHoleIndex rootName argNames args of
        Just i  -> [(Opt.ConsCtor (Opt.Global home name) (length args), i)]
        Nothing -> []

    Can.If branches finally ->
      concatMap (collectConsCandidates rootName argNames . snd) branches
        ++ collectConsCandidates rootName argNames finally

    Can.Let _ body ->
      collectConsCandidates rootName argNames body

    Can.LetRec _ body ->
      collectConsCandidates rootName argNames body

    Can.LetDestruct _ _ body ->
      collectConsCandidates rootName argNames body

    Can.Case _ branches ->
      concatMap (\(Can.CaseBranch _ branch) -> collectConsCandidates rootName argNames branch) branches

    _ ->
      []


consArity :: Opt.ConsInfo -> Int
consArity consInfo =
  case consInfo of
    Opt.ConsKernel   -> 2
    Opt.ConsCtor _ n -> n


-- Does a Can.Expr, if it is exactly a saturated self-call, match the
-- function being defined? Used for both the ordinary Opt.TailCall case
-- and (here) the recursive operand of a `::` modulo-cons step.
matchTailSelfCall :: Hints -> Cycle -> Name.Name -> [Name.Name] -> Can.Expr -> Names.Tracker (Maybe [(Name.Name, Opt.Expr)])
matchTailSelfCall hints cycle rootName argNames (A.At _ expression) =
  case expression of
    Can.Call func args ->
      let
        isMatchingName =
          case A.toValue func of
            Can.VarLocal      name -> rootName == name
            Can.VarTopLevel _ name -> rootName == name
            _                      -> False
      in
      if isMatchingName then
        do  oargs <- traverse (optimize hints cycle) args
            case Index.indexedZipWith (\_ a b -> (a,b)) argNames oargs of
              Index.LengthMatch pairs  -> pure (Just pairs)
              Index.LengthMismatch _ _ -> pure Nothing
      else
        pure Nothing

    _ ->
      pure Nothing


-- Does this (already optimized) tail body contain a TailCallCons anywhere
-- reachable in tail position? If so, the whole def needs the sentinel/
-- hole-mutation wrapper instead of the plain label+while loop.
hasTailCallCons :: Opt.Expr -> Bool
hasTailCallCons expression =
  case expression of
    Opt.TailCallCons _ _ _ _ _ ->
      True

    Opt.If branches finally ->
      hasTailCallCons finally || any (hasTailCallCons . snd) branches

    Opt.Let _ body ->
      hasTailCallCons body

    Opt.Destruct _ body ->
      hasTailCallCons body

    Opt.Case _ _ decider jumps ->
      deciderHasTailCallCons decider || any (hasTailCallCons . snd) jumps

    _ ->
      False


deciderHasTailCallCons :: Opt.Decider Opt.Choice -> Bool
deciderHasTailCallCons decider =
  case decider of
    Opt.Leaf (Opt.Inline expr) ->
      hasTailCallCons expr

    Opt.Leaf (Opt.Jump _) ->
      False

    Opt.Chain _ success failure ->
      deciderHasTailCallCons success || deciderHasTailCallCons failure

    Opt.FanOut _ tests fallback ->
      deciderHasTailCallCons fallback || any (deciderHasTailCallCons . snd) tests


-- Once a def is known to need the modulo-cons wrapper, every leaf that is
-- not already a recursive step (TailCall/TailCallCons) is a base case:
-- wrap it so codegen fills the open hole and returns, instead of just
-- returning the value directly.
wrapConsBase :: Index.ZeroBased -> Name.Name -> Opt.Expr -> Opt.Expr
wrapConsBase holeIndex rootName expression =
  case expression of
    Opt.TailCall _ _ ->
      expression

    Opt.TailCallCons _ _ _ _ _ ->
      expression

    Opt.If branches finally ->
      Opt.If (map (\(c,b) -> (c, wrapConsBase holeIndex rootName b)) branches) (wrapConsBase holeIndex rootName finally)

    Opt.Let def body ->
      Opt.Let def (wrapConsBase holeIndex rootName body)

    Opt.Destruct destructor body ->
      Opt.Destruct destructor (wrapConsBase holeIndex rootName body)

    Opt.Case label root decider jumps ->
      Opt.Case label root (wrapConsBaseDecider holeIndex rootName decider) (map (\(i,e) -> (i, wrapConsBase holeIndex rootName e)) jumps)

    _ ->
      Opt.TailCallConsBase holeIndex rootName expression


wrapConsBaseDecider :: Index.ZeroBased -> Name.Name -> Opt.Decider Opt.Choice -> Opt.Decider Opt.Choice
wrapConsBaseDecider holeIndex rootName decider =
  case decider of
    Opt.Leaf (Opt.Inline expr) ->
      Opt.Leaf (Opt.Inline (wrapConsBase holeIndex rootName expr))

    Opt.Leaf (Opt.Jump index) ->
      Opt.Leaf (Opt.Jump index)

    Opt.Chain testChain success failure ->
      Opt.Chain testChain (wrapConsBaseDecider holeIndex rootName success) (wrapConsBaseDecider holeIndex rootName failure)

    Opt.FanOut path tests fallback ->
      Opt.FanOut path (map (\(t,d) -> (t, wrapConsBaseDecider holeIndex rootName d)) tests) (wrapConsBaseDecider holeIndex rootName fallback)



-- TAIL CALL


optimizePotentialTailCallDef :: Hints -> Cycle -> Can.Def -> Names.Tracker Opt.Def
optimizePotentialTailCallDef hints cycle def =
  case def of
    Can.Def (A.At _ name) args expr ->
      optimizePotentialTailCall hints cycle name args expr

    Can.TypedDef (A.At _ name) _ typedArgs expr _ ->
      optimizePotentialTailCall hints cycle name (map fst typedArgs) expr


optimizePotentialTailCall :: Hints -> Cycle -> Name.Name -> [Can.Pattern] -> Can.Expr -> Names.Tracker Opt.Def
optimizePotentialTailCall hints cycle name args expr =
  do  (argNames, destructors) <- destructArgs args
      let consIdentity = detectConsIdentity name argNames expr
      toTailDef consIdentity name argNames destructors <$>
        optimizeTail hints cycle consIdentity name argNames expr


optimizeTail :: Hints -> Cycle -> Maybe (Opt.ConsInfo, Index.ZeroBased) -> Name.Name -> [Name.Name] -> Can.Expr -> Names.Tracker Opt.Expr
optimizeTail hints cycle consIdentity rootName argNames locExpr@(A.At _ expression) =
  case expression of
    Can.Call (A.At _ (Can.VarCtor Can.Normal home name index _)) args
      | Just (Opt.ConsCtor (Opt.Global cHome cName) cArity, holeIndex) <- consIdentity
      , home == cHome && name == cName && cArity == length args
      , findHoleIndex rootName argNames args == Just holeIndex
      ->
        do  _ <- Names.registerCtor home name index Can.Normal
            maybeRebinds <- matchTailSelfCall hints cycle rootName argNames (args !! Index.toMachine holeIndex)
            case maybeRebinds of
              Just rebinds ->
                do  otherFields <- traverse
                                      (\(i, a) -> (,) i <$> optimize hints cycle a)
                                      (otherIndexedArgs holeIndex args)
                    pure $ Opt.TailCallCons
                             (Opt.ConsCtor (Opt.Global home name) cArity) holeIndex rootName
                             otherFields rebinds

              Nothing ->
                optimize hints cycle locExpr

    Can.Call func args ->
      do  oargs <- traverse (optimize hints cycle) args

          let isMatchingName =
                case A.toValue func of
                  Can.VarLocal      name -> rootName == name
                  Can.VarTopLevel _ name -> rootName == name
                  _                      -> False

          if isMatchingName
            then
              case Index.indexedZipWith (\_ a b -> (a,b)) argNames oargs of
                Index.LengthMatch pairs ->
                  pure $ Opt.TailCall rootName pairs

                Index.LengthMismatch _ _ ->
                  do  ofunc <- optimize hints cycle func
                      pure $ Opt.Call ofunc oargs
            else
              do  ofunc <- optimize hints cycle func
                  pure $ Opt.Call ofunc oargs

    Can.Binop _ home name _ left right | isListCons home name ->
      if consIdentity == Just (Opt.ConsKernel, Index.second) then
        do  maybeRebinds <- matchTailSelfCall hints cycle rootName argNames right
            case maybeRebinds of
              Just rebinds ->
                do  optHead <- optimize hints cycle left
                    Names.registerKernel Name.list
                      (Opt.TailCallCons Opt.ConsKernel Index.second rootName [(Index.first, optHead)] rebinds)

              Nothing ->
                optimize hints cycle locExpr
      else
        optimize hints cycle locExpr

    Can.If branches finally ->
      let
        optimizeBranch (condition, branch) =
          (,)
            <$> optimize hints cycle condition
            <*> optimizeTail hints cycle consIdentity rootName argNames branch
      in
      Opt.If
        <$> traverse optimizeBranch branches
        <*> optimizeTail hints cycle consIdentity rootName argNames finally

    Can.Let def body ->
      optimizeDef hints cycle def =<< optimizeTail hints cycle consIdentity rootName argNames body

    Can.LetRec defs body ->
      case defs of
        [def] ->
          Opt.Let
            <$> optimizePotentialTailCallDef hints cycle def
            <*> optimizeTail hints cycle consIdentity rootName argNames body

        _ ->
          do  obody <- optimizeTail hints cycle consIdentity rootName argNames body
              foldM (\bod def -> optimizeDef hints cycle def bod) obody defs

    Can.LetDestruct pattern expr body ->
      do  (dname, destructors) <- destruct pattern
          oexpr <- optimize hints cycle expr
          obody <- optimizeTail hints cycle consIdentity rootName argNames body
          pure $
            Opt.Let (Opt.Def dname oexpr) (foldr Opt.Destruct obody destructors)

    Can.Case expr branches ->
      let
        optimizeBranch root (Can.CaseBranch pattern branch) =
          do  destructors <- destructCase root pattern
              obranch <- optimizeTail hints cycle consIdentity rootName argNames branch
              pure (pattern, foldr Opt.Destruct obranch destructors)
      in
      do  temp <- Names.generate
          oexpr <- optimize hints cycle expr
          case oexpr of
            Opt.VarLocal root ->
              Case.optimize temp root <$> traverse (optimizeBranch root) branches

            _ ->
              do  obranches <- traverse (optimizeBranch temp) branches
                  return $ Opt.Let (Opt.Def temp oexpr) (Case.optimize temp temp obranches)

    _ ->
      optimize hints cycle locExpr



-- DETECT TAIL CALLS


toTailDef :: Maybe (Opt.ConsInfo, Index.ZeroBased) -> Name.Name -> [Name.Name] -> [Opt.Destructor] -> Opt.Expr -> Opt.Def
toTailDef consIdentity name argNames destructors body =
  case consIdentity of
    Just (consInfo, holeIndex) | hasTailCallCons body ->
      Opt.TailDefCons consInfo holeIndex (consArity consInfo) name argNames
        (wrapConsBase holeIndex name (foldr Opt.Destruct body destructors))

    _ ->
      if hasTailCall body then
        Opt.TailDef name argNames (foldr Opt.Destruct body destructors)
      else
        Opt.Def name (Opt.Function argNames (foldr Opt.Destruct body destructors))


hasTailCall :: Opt.Expr -> Bool
hasTailCall expression =
  case expression of
    Opt.TailCall _ _ ->
      True

    Opt.TailCallCons _ _ _ _ _ ->
      True

    Opt.If branches finally ->
      hasTailCall finally || any (hasTailCall . snd) branches

    Opt.Let _ body ->
      hasTailCall body

    Opt.Destruct _ body ->
      hasTailCall body

    Opt.Case _ _ decider jumps ->
      decidecHasTailCall decider || any (hasTailCall . snd) jumps

    _ ->
      False


decidecHasTailCall :: Opt.Decider Opt.Choice -> Bool
decidecHasTailCall decider =
  case decider of
    Opt.Leaf choice ->
      case choice of
        Opt.Inline expr ->
          hasTailCall expr

        Opt.Jump _ ->
          False

    Opt.Chain _ success failure ->
      decidecHasTailCall success || decidecHasTailCall failure

    Opt.FanOut _ tests fallback ->
      decidecHasTailCall fallback || any (decidecHasTailCall . snd) tests
