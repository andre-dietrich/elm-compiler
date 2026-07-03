{-# LANGUAGE OverloadedStrings #-}
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

    Can.Call func args ->
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
      Names.registerKernel Name.utils Opt.Tuple
        <*> optimize hints cycle a
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
      toTailDef name argNames destructors <$>
        optimizeTail hints cycle name argNames expr


optimizeTail :: Hints -> Cycle -> Name.Name -> [Name.Name] -> Can.Expr -> Names.Tracker Opt.Expr
optimizeTail hints cycle rootName argNames locExpr@(A.At _ expression) =
  case expression of
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

    Can.If branches finally ->
      let
        optimizeBranch (condition, branch) =
          (,)
            <$> optimize hints cycle condition
            <*> optimizeTail hints cycle rootName argNames branch
      in
      Opt.If
        <$> traverse optimizeBranch branches
        <*> optimizeTail hints cycle rootName argNames finally

    Can.Let def body ->
      optimizeDef hints cycle def =<< optimizeTail hints cycle rootName argNames body

    Can.LetRec defs body ->
      case defs of
        [def] ->
          Opt.Let
            <$> optimizePotentialTailCallDef hints cycle def
            <*> optimizeTail hints cycle rootName argNames body

        _ ->
          do  obody <- optimizeTail hints cycle rootName argNames body
              foldM (\bod def -> optimizeDef hints cycle def bod) obody defs

    Can.LetDestruct pattern expr body ->
      do  (dname, destructors) <- destruct pattern
          oexpr <- optimize hints cycle expr
          obody <- optimizeTail hints cycle rootName argNames body
          pure $
            Opt.Let (Opt.Def dname oexpr) (foldr Opt.Destruct obody destructors)

    Can.Case expr branches ->
      let
        optimizeBranch root (Can.CaseBranch pattern branch) =
          do  destructors <- destructCase root pattern
              obranch <- optimizeTail hints cycle rootName argNames branch
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


toTailDef :: Name.Name -> [Name.Name] -> [Opt.Destructor] -> Opt.Expr -> Opt.Def
toTailDef name argNames destructors body =
  if hasTailCall body then
    Opt.TailDef name argNames (foldr Opt.Destruct body destructors)
  else
    Opt.Def name (Opt.Function argNames (foldr Opt.Destruct body destructors))


hasTailCall :: Opt.Expr -> Bool
hasTailCall expression =
  case expression of
    Opt.TailCall _ _ ->
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
