{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Nitpick.Worker
  ( check
  )
  where


import qualified Data.Map as Map
import qualified Data.Name as Name
import qualified Data.NonEmptyList as NE
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Utils.Type as Type
import qualified Canonicalize.Effects as Effects
import qualified Elm.ModuleName as ModuleName
import qualified Optimize.Expression as Expr (collectApplication)
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Worker as Error



-- CHECK
--
-- Validates every `Worker.run fn ...` call site in a module: `fn` must be a
-- bare reference to a top-level function (no lambdas, no partial
-- application, no local captures), not part of a same-module mutually
-- recursive group (see Reporting.Error.Worker.InCyclicGroup for why), and
-- its domain/codomain types must be safe to carry across a worker boundary
-- -- the exact same restriction ports already enforce, reused verbatim via
-- Canonicalize.Effects.checkPayload.
--
-- NOTE: this only catches the cyclic-group case for functions declared in
-- *this* module. A `Can.VarForeign` reference into another module's own
-- recursive group is not detected here, since Nitpick runs per-module and
-- only has that module's own Can.Decls to inspect -- a known gap, cheap to
-- accept for the M1 top-level-only phase.


check :: Map.Map Name.Name Can.Annotation -> Can.Module -> Either (NE.List Error.Error) ()
check annotations (Can.Module _ _ _ decls _ _ _ _) =
  let
    cyclic = cyclicNames decls
  in
  case checkDecls annotations cyclic decls [] of
    [] ->
      Right ()

    e:es ->
      Left (NE.List e es)



-- CYCLIC NAMES


cyclicNames :: Can.Decls -> Set.Set Name.Name
cyclicNames decls =
  case decls of
    Can.Declare _ subDecls ->
      cyclicNames subDecls

    Can.DeclareRec def defs subDecls ->
      Set.union (Set.fromList (map defName (def : defs))) (cyclicNames subDecls)

    Can.SaveTheEnvironment ->
      Set.empty


defName :: Can.Def -> Name.Name
defName def =
  case def of
    Can.Def (A.At _ name) _ _ ->
      name

    Can.TypedDef (A.At _ name) _ _ _ _ ->
      name



-- CHECK DECLS


checkDecls :: Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.Decls -> [Error.Error] -> [Error.Error]
checkDecls annotations cyclic decls errors =
  case decls of
    Can.Declare def subDecls ->
      checkDef annotations cyclic def (checkDecls annotations cyclic subDecls errors)

    Can.DeclareRec def defs subDecls ->
      foldr (checkDef annotations cyclic) (checkDecls annotations cyclic subDecls errors) (def : defs)

    Can.SaveTheEnvironment ->
      errors


checkDef :: Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.Def -> [Error.Error] -> [Error.Error]
checkDef annotations cyclic def errors =
  case def of
    Can.Def _ _ body ->
      checkExpr annotations cyclic body errors

    Can.TypedDef _ _ _ body _ ->
      checkExpr annotations cyclic body errors



-- CHECK EXPRESSIONS


checkExpr :: Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.Expr -> [Error.Error] -> [Error.Error]
checkExpr annotations cyclic wholeExpr@(A.At region expression) errors =
  case expression of
    -- Recognizes a `Worker.run fn ...` call regardless of whether it was
    -- written as ordinary application or a `|>`/`<|` pipe -- collectApplication
    -- (shared with Optimize.Expression, which performs the actual call-site
    -- rewrite later) normalizes both to the same (callee, args) shape, so
    -- the two passes can never disagree about which syntactic forms count.
    -- Requires at least one argument (`fnArg : dataArgs`) so a bare,
    -- unapplied `Worker.run` falls through to the VarForeign case below
    -- instead.
    _ | (A.At _ (Can.VarForeign home name _), fnArg : dataArgs) <- Expr.collectApplication wholeExpr
      , home == ModuleName.worker, name == "run"
      ->
        checkRun annotations cyclic region fnArg $
          foldr (checkExpr annotations cyclic) errors dataArgs

    Can.VarLocal _ ->
      errors

    Can.VarTopLevel _ _ ->
      errors

    Can.VarKernel _ _ ->
      errors

    Can.VarForeign home name _
      | home == ModuleName.worker, name == "run" ->
          Error.UnappliedRun region : errors

    Can.VarForeign _ _ _ ->
      errors

    Can.VarCtor _ _ _ _ _ ->
      errors

    Can.VarDebug _ _ _ ->
      errors

    Can.VarOperator _ _ _ _ ->
      errors

    Can.Chr _ ->
      errors

    Can.Str _ ->
      errors

    Can.Int _ ->
      errors

    Can.Float _ ->
      errors

    Can.List entries ->
      foldr (checkExpr annotations cyclic) errors entries

    Can.Negate expr ->
      checkExpr annotations cyclic expr errors

    Can.Binop _ _ _ _ left right ->
      checkExpr annotations cyclic left $
        checkExpr annotations cyclic right errors

    Can.Lambda _args body ->
      checkExpr annotations cyclic body errors

    Can.Call func args ->
      checkExpr annotations cyclic func $
        foldr (checkExpr annotations cyclic) errors args

    Can.If branches finally ->
      foldr (checkIfBranch annotations cyclic) (checkExpr annotations cyclic finally errors) branches

    Can.Let def body ->
      checkDef annotations cyclic def (checkExpr annotations cyclic body errors)

    Can.LetRec defs body ->
      foldr (checkDef annotations cyclic) (checkExpr annotations cyclic body errors) defs

    Can.LetDestruct _ expr body ->
      checkExpr annotations cyclic expr $
        checkExpr annotations cyclic body errors

    Can.Case expr branches ->
      checkExpr annotations cyclic expr $
        foldr (checkCaseBranch annotations cyclic) errors branches

    Can.Accessor _ ->
      errors

    Can.Access record _ ->
      checkExpr annotations cyclic record errors

    Can.Update _ record fields ->
      checkExpr annotations cyclic record $
        Map.foldr (checkField annotations cyclic) errors fields

    Can.Record fields ->
      Map.foldr (checkExpr annotations cyclic) errors fields

    Can.Unit ->
      errors

    Can.Tuple a b maybeC ->
      checkExpr annotations cyclic a $
        checkExpr annotations cyclic b $
          case maybeC of
            Nothing ->
              errors

            Just c ->
              checkExpr annotations cyclic c errors

    Can.Shader _ _ ->
      errors


checkIfBranch :: Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> (Can.Expr, Can.Expr) -> [Error.Error] -> [Error.Error]
checkIfBranch annotations cyclic (condition, branch) errors =
  checkExpr annotations cyclic condition $
    checkExpr annotations cyclic branch errors


checkCaseBranch :: Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.CaseBranch -> [Error.Error] -> [Error.Error]
checkCaseBranch annotations cyclic (Can.CaseBranch _ branch) errors =
  checkExpr annotations cyclic branch errors


checkField :: Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.FieldUpdate -> [Error.Error] -> [Error.Error]
checkField annotations cyclic (Can.FieldUpdate _ expr) errors =
  checkExpr annotations cyclic expr errors



-- CHECK Worker.run's fn ARGUMENT


checkRun :: Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> A.Region -> Can.Expr -> [Error.Error] -> [Error.Error]
checkRun annotations cyclic region fnArg errors =
  case fnArg of
    A.At _ (Can.VarTopLevel _ name) ->
      case Map.lookup name annotations of
        Just (Can.Forall _ tipe) ->
          checkCyclic cyclic region name $
            checkFnType region tipe errors

        Nothing ->
          -- Every top-level def in this module has an entry in `annotations`
          -- (populated during type-checking, before Nitpick runs) -- a miss
          -- here means this isn't actually a plain top-level reference to a
          -- def in this module, so fail closed rather than crash.
          Error.NotATopLevelFunction region : errors

    A.At _ (Can.VarForeign _ _ (Can.Forall _ tipe)) ->
      checkFnType region tipe errors

    _ ->
      Error.NotATopLevelFunction region : errors


checkCyclic :: Set.Set Name.Name -> A.Region -> Name.Name -> [Error.Error] -> [Error.Error]
checkCyclic cyclic region name errors =
  if Set.member name cyclic then
    Error.InCyclicGroup region name : errors
  else
    errors


-- Worker.run : (a -> b) -> a -> Task x b, so Elm's own type checker already
-- guarantees fnArg's type is *some* function by the time Nitpick runs.
-- delambda always fully uncurries a TLambda chain (regardless of depth), so
-- exactly two elements back means fnArg is a plain unary function `a -> b`;
-- anything else means a curried multi-argument function, which is just as
-- unrepresentable across a worker boundary as any other function value.
checkFnType :: A.Region -> Can.Type -> [Error.Error] -> [Error.Error]
checkFnType region tipe errors =
  case Type.delambda (Type.deepDealias tipe) of
    [argType, resultType] ->
      checkPayloadType region argType $
        checkPayloadType region resultType errors

    _ ->
      Error.NotATopLevelFunction region : errors


checkPayloadType :: A.Region -> Can.Type -> [Error.Error] -> [Error.Error]
checkPayloadType region tipe errors =
  case Effects.checkPayload tipe of
    Right () ->
      errors

    Left (badType, invalidPayload) ->
      Error.BadPayload region badType invalidPayload : errors
