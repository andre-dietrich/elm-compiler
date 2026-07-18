{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Optimize.Expression
  ( optimize
  , Hints
  , destructArgs
  , optimizePotentialTailCall
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
import qualified Data.Index as Index
import qualified Elm.ModuleName as ModuleName
import qualified Optimize.Case as Case
import qualified Optimize.Names as Names
import qualified Reporting.Annotation as A
import qualified Type.Type as Type



-- OPTIMIZE


type Cycle =
  Set.Set Name.Name


-- Resolved primitive type of comparison/append Binop call sites, keyed by
-- the Binop's region. Populated by Type.Solve from CProbe constraints; see
-- Type.Type's PrimType. Absent entries mean "not proven monomorphic",
-- keeping the generic Basics.eq/append call.
type Hints =
  Map.Map A.Region Type.PrimType


optimize :: Hints -> Cycle -> Can.Expr -> Names.Tracker Opt.Expr
optimize hints cycle (A.At region expression) =
  case expression of
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
      case Map.lookup region hints >>= toPrimBinop home name of
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

    Can.Call func args
      | Can.VarForeign home name _ <- A.toValue func
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
      case Map.lookup region hints of
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
  = StageMap Can.Expr Can.Expr     -- f, inner list expr
  | StageFilter Can.Expr Can.Expr  -- p, inner list expr


-- Nothing => not a recognized producer shape (the true source list, or a
-- fusion barrier this pass doesn't understand, e.g. sortBy/filterMap) =>
-- stop peeling here. Only elm/core's own List.map/List.filter match;
-- everything else (including a local `myMap = List.map` alias) falls
-- through untouched.
peelListStage :: Can.Expr -> Maybe ListStage
peelListStage (A.At _ expression) =
  case expression of
    Can.Call (A.At _ (Can.VarForeign home name _)) [f, inner]
      | home == ModuleName.list, name == "map" ->
          Just (StageMap f inner)
      | home == ModuleName.list, name == "filter" ->
          Just (StageFilter f inner)
    _ ->
      Nothing


stageInner :: ListStage -> Can.Expr
stageInner (StageMap _ inner)    = inner
stageInner (StageFilter _ inner) = inner


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
