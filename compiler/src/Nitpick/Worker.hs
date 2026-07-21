{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Nitpick.Worker
  ( check
  )
  where


import qualified Data.Foldable as F
import qualified Data.Map as Map
import qualified Data.Name as Name
import qualified Data.NonEmptyList as NE
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified AST.Utils.Type as Type
import qualified Elm.Interface as I
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
-- its domain/codomain types must be safe to structured-clone across a
-- worker boundary -- see checkClonable below. Unlike ports (Canonicalize
-- .Effects.checkPayload), this is NOT a JSON-payload whitelist: Worker.run
-- no longer encodes/decodes anything (see Optimize.Expression's
-- buildWorkerRun), it hands the raw compiled JS value straight to
-- postMessage, relying on the main thread and the worker loading byte-for-
-- byte the same compiled bundle (same ctor tags / shape padding / field
-- names either way). So the only real question is whether the value could
-- ever contain a JS function -- structured clone rejects those outright.
--
-- NOTE: this only catches the cyclic-group case for functions declared in
-- *this* module. A `Can.VarForeign` reference into another module's own
-- recursive group is not detected here, since Nitpick runs per-module and
-- only has that module's own Can.Decls to inspect -- a known gap, cheap to
-- accept for the M1 top-level-only phase.


check :: Map.Map ModuleName.Raw I.Interface -> Map.Map Name.Name Can.Annotation -> Can.Module -> Either (NE.List Error.Error) ()
check ifaces annotations (Can.Module home _ _ decls unions _ _ _) =
  let
    cyclic = cyclicNames decls
    ctx = Ctx home unions ifaces
  in
  case checkDecls ctx annotations cyclic decls [] of
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


checkDecls :: Ctx -> Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.Decls -> [Error.Error] -> [Error.Error]
checkDecls ctx annotations cyclic decls errors =
  case decls of
    Can.Declare def subDecls ->
      checkDef ctx annotations cyclic def (checkDecls ctx annotations cyclic subDecls errors)

    Can.DeclareRec def defs subDecls ->
      foldr (checkDef ctx annotations cyclic) (checkDecls ctx annotations cyclic subDecls errors) (def : defs)

    Can.SaveTheEnvironment ->
      errors


checkDef :: Ctx -> Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.Def -> [Error.Error] -> [Error.Error]
checkDef ctx annotations cyclic def errors =
  case def of
    Can.Def _ _ body ->
      checkExpr ctx annotations cyclic body errors

    Can.TypedDef _ _ _ body _ ->
      checkExpr ctx annotations cyclic body errors



-- CHECK EXPRESSIONS


checkExpr :: Ctx -> Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.Expr -> [Error.Error] -> [Error.Error]
checkExpr ctx annotations cyclic wholeExpr@(A.At region expression) errors =
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
        checkRun ctx annotations cyclic region fnArg $
          foldr (checkExpr ctx annotations cyclic) errors dataArgs

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
      foldr (checkExpr ctx annotations cyclic) errors entries

    Can.Negate expr ->
      checkExpr ctx annotations cyclic expr errors

    Can.Binop _ _ _ _ left right ->
      checkExpr ctx annotations cyclic left $
        checkExpr ctx annotations cyclic right errors

    Can.Lambda _args body ->
      checkExpr ctx annotations cyclic body errors

    Can.Call func args ->
      checkExpr ctx annotations cyclic func $
        foldr (checkExpr ctx annotations cyclic) errors args

    Can.If branches finally ->
      foldr (checkIfBranch ctx annotations cyclic) (checkExpr ctx annotations cyclic finally errors) branches

    Can.Let def body ->
      checkDef ctx annotations cyclic def (checkExpr ctx annotations cyclic body errors)

    Can.LetRec defs body ->
      foldr (checkDef ctx annotations cyclic) (checkExpr ctx annotations cyclic body errors) defs

    Can.LetDestruct _ expr body ->
      checkExpr ctx annotations cyclic expr $
        checkExpr ctx annotations cyclic body errors

    Can.Case expr branches ->
      checkExpr ctx annotations cyclic expr $
        foldr (checkCaseBranch ctx annotations cyclic) errors branches

    Can.Accessor _ ->
      errors

    Can.Access record _ ->
      checkExpr ctx annotations cyclic record errors

    Can.Update _ record fields ->
      checkExpr ctx annotations cyclic record $
        Map.foldr (checkField ctx annotations cyclic) errors fields

    Can.Record fields ->
      Map.foldr (checkExpr ctx annotations cyclic) errors fields

    Can.Unit ->
      errors

    Can.Tuple a b maybeC ->
      checkExpr ctx annotations cyclic a $
        checkExpr ctx annotations cyclic b $
          case maybeC of
            Nothing ->
              errors

            Just c ->
              checkExpr ctx annotations cyclic c errors

    Can.Shader _ _ ->
      errors


checkIfBranch :: Ctx -> Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> (Can.Expr, Can.Expr) -> [Error.Error] -> [Error.Error]
checkIfBranch ctx annotations cyclic (condition, branch) errors =
  checkExpr ctx annotations cyclic condition $
    checkExpr ctx annotations cyclic branch errors


checkCaseBranch :: Ctx -> Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.CaseBranch -> [Error.Error] -> [Error.Error]
checkCaseBranch ctx annotations cyclic (Can.CaseBranch _ branch) errors =
  checkExpr ctx annotations cyclic branch errors


checkField :: Ctx -> Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> Can.FieldUpdate -> [Error.Error] -> [Error.Error]
checkField ctx annotations cyclic (Can.FieldUpdate _ expr) errors =
  checkExpr ctx annotations cyclic expr errors



-- CHECK Worker.run's fn ARGUMENT


checkRun :: Ctx -> Map.Map Name.Name Can.Annotation -> Set.Set Name.Name -> A.Region -> Can.Expr -> [Error.Error] -> [Error.Error]
checkRun ctx annotations cyclic region fnArg errors =
  case fnArg of
    A.At _ (Can.VarTopLevel _ name) ->
      case Map.lookup name annotations of
        Just (Can.Forall _ tipe) ->
          checkCyclic cyclic region name $
            checkFnType ctx region tipe errors

        Nothing ->
          -- Every top-level def in this module has an entry in `annotations`
          -- (populated during type-checking, before Nitpick runs) -- a miss
          -- here means this isn't actually a plain top-level reference to a
          -- def in this module, so fail closed rather than crash.
          Error.NotATopLevelFunction region : errors

    A.At _ (Can.VarForeign _ _ (Can.Forall _ tipe)) ->
      checkFnType ctx region tipe errors

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
checkFnType :: Ctx -> A.Region -> Can.Type -> [Error.Error] -> [Error.Error]
checkFnType ctx region tipe errors =
  case Type.delambda (Type.deepDealias tipe) of
    [argType, resultType] ->
      checkPayloadType ctx region argType $
        checkPayloadType ctx region resultType errors

    _ ->
      Error.NotATopLevelFunction region : errors


checkPayloadType :: Ctx -> A.Region -> Can.Type -> [Error.Error] -> [Error.Error]
checkPayloadType ctx region tipe errors =
  case checkClonable ctx Set.empty tipe of
    Right () ->
      errors

    Left (badType, invalidPayload) ->
      Error.BadPayload region badType invalidPayload : errors



-- CHECK CLONABLE
--
-- Whether a type is safe to structured-clone across a worker boundary: not
-- a JSON whitelist (see the module comment up top), but still a whitelist,
-- because some opaque kernel-backed types embed a JS closure in their
-- runtime representation with no trace of that in the Elm type itself (e.g.
-- `Html.Html msg` carries event-handler functions inside VirtualDom nodes).
-- Structural "no TLambda anywhere in this type" is therefore unsound on its
-- own -- an opaque type's hidden constructors could contain anything. So:
-- primitives and known-safe opaque types are hardcoded (mirroring
-- Canonicalize.Effects.checkPayload's style), and anything else is only
-- accepted if its constructors are actually visible (an "open" union, this
-- module's own or a directly-imported module's), recursively checking every
-- constructor's argument types. Closed/private unions (hidden constructors)
-- and unions whose defining module isn't directly imported here both fail
-- closed with the same OpaqueType error -- see Reporting.Error.Worker's
-- comment on why those two cases share one error constructor.


data Ctx =
  Ctx
    { _ctxHome :: ModuleName.Canonical
    , _ctxLocalUnions :: Map.Map Name.Name Can.Union
    , _ctxIfaces :: Map.Map ModuleName.Raw I.Interface
    }


-- Tracks which (module, type name) pairs are already being verified further
-- up the call stack, so a self-referential type (`type Tree = Leaf | Node
-- Tree Tree`) or a mutually recursive pair terminates instead of looping
-- forever: revisiting a pair already in progress is treated as safe
-- (coinductively -- soundness here rests on the SAME reasoning that lets
-- `_Utils_eq`/`Debug.toString` walk recursive values at runtime without
-- special-casing recursive types, just applied at the type level instead of
-- the value level).
type Seen =
  Set.Set (ModuleName.Canonical, Name.Name)


checkClonable :: Ctx -> Seen -> Can.Type -> Either (Can.Type, Error.InvalidPayload) ()
checkClonable ctx seen tipe =
  case tipe of
    Can.TAlias _ _ args aliasedType ->
      checkClonable ctx seen (Type.dealias args aliasedType)

    Can.TUnit ->
      Right ()

    Can.TTuple a b maybeC ->
      do  checkClonable ctx seen a
          checkClonable ctx seen b
          case maybeC of
            Nothing -> Right ()
            Just c  -> checkClonable ctx seen c

    Can.TVar name ->
      Left (tipe, Error.TypeVariable name)

    Can.TLambda _ _ ->
      Left (tipe, Error.Function)

    Can.TRecord _ (Just _) ->
      Left (tipe, Error.ExtendedRecord)

    Can.TRecord fields Nothing ->
      F.traverse_ (checkFieldClonable ctx seen) fields

    Can.TType home name args ->
      checkTType ctx seen tipe home name args


checkFieldClonable :: Ctx -> Seen -> Can.FieldType -> Either (Can.Type, Error.InvalidPayload) ()
checkFieldClonable ctx seen (Can.FieldType _ fieldType) =
  checkClonable ctx seen fieldType


checkTType :: Ctx -> Seen -> Can.Type -> ModuleName.Canonical -> Name.Name -> [Can.Type] -> Either (Can.Type, Error.InvalidPayload) ()
checkTType ctx seen tipe home name args
  | null args, isPrimitive home name =
      Right ()

  | null args, isJson home name =
      Right ()

  -- Dict/Set: plain tagged JS object graphs at runtime (RBNode trees), so
  -- safe to clone, but elm/core does not export their constructors, so they
  -- can never be verified via the generic open-union path below. Their type
  -- arguments (key/value/element types) still get checked recursively --
  -- `Dict String (Int -> Int)` must still be rejected.
  | isOpaqueButClonable home name =
      F.traverse_ (checkClonable ctx seen) args

  | [arg] <- args, isSingleArgContainer home name =
      checkClonable ctx seen arg

  | otherwise =
      checkUserUnion ctx seen tipe home name args


isPrimitive :: ModuleName.Canonical -> Name.Name -> Bool
isPrimitive home name =
  (home == ModuleName.basics && (name == Name.int || name == Name.float || name == Name.bool))
  || (home == ModuleName.string && name == Name.string)
  || (home == ModuleName.char && name == Name.char)


isJson :: ModuleName.Canonical -> Name.Name -> Bool
isJson home name =
  home == ModuleName.jsonEncode && name == Name.value


isOpaqueButClonable :: ModuleName.Canonical -> Name.Name -> Bool
isOpaqueButClonable home name =
  (home == ModuleName.dict && name == Name.dict)
  || (home == ModuleName.set && name == Name.set)


isSingleArgContainer :: ModuleName.Canonical -> Name.Name -> Bool
isSingleArgContainer home name =
  (home == ModuleName.list && name == Name.list)
  || (home == ModuleName.maybe && name == Name.maybe)
  || (home == ModuleName.array && name == Name.array)


-- Handles every other TType: elm/core's own open unions (Result, Order),
-- and any user-defined custom type -- as long as its constructors are
-- actually visible from here (see resolveUnion).
checkUserUnion :: Ctx -> Seen -> Can.Type -> ModuleName.Canonical -> Name.Name -> [Can.Type] -> Either (Can.Type, Error.InvalidPayload) ()
checkUserUnion ctx seen tipe home name args =
  if Set.member (home, name) seen then
    Right ()
  else
    case resolveUnion ctx home name of
      Nothing ->
        Left (tipe, Error.OpaqueType name)

      Just (Can.Union vars ctors _ _) ->
        let seen' = Set.insert (home, name) seen in
        F.traverse_ (checkCtor ctx seen' vars args) ctors


checkCtor :: Ctx -> Seen -> [Name.Name] -> [Can.Type] -> Can.Ctor -> Either (Can.Type, Error.InvalidPayload) ()
checkCtor ctx seen vars args (Can.Ctor _ _ _ argTypes) =
  F.traverse_ (checkClonable ctx seen . substitute vars args) argTypes


-- Reuses AST.Utils.Type's own alias-substitution machinery (Holey/dealias)
-- to apply a union's type-variable instantiation to one of its constructor's
-- argument types -- e.g. `type Pair a = Pair a a` used at `Pair Int`
-- substitutes `a := Int` into each `a` occurrence in `Pair`'s ctor arg.
substitute :: [Name.Name] -> [Can.Type] -> Can.Type -> Can.Type
substitute vars args tipe =
  Type.dealias (zip vars args) (Can.Holey tipe)


-- Resolves a TType's Can.Union, ONLY if its constructors are actually
-- visible from the module currently being checked: either it's a type this
-- module defines itself (always fully visible in Can.Module's own _unions,
-- export status notwithstanding), or it's defined in a module this one
-- directly imports (visible in `ifaces`) AND that module chose to export it
-- as an OpenUnion (constructors included).
--
-- Deliberately does NOT use Elm.Interface.toPublicUnion here: that function
-- turns a ClosedUnion into `Just (Can.Union vars [] 0 opts)` -- a union with
-- ZERO constructors -- which would make checkUserUnion's `traverse_` over an
-- empty ctor list vacuously succeed, silently treating a genuinely opaque
-- type (e.g. `Html.Html`, hidden constructors on purpose) as safe. Pattern
-- matching Interface.Union directly avoids that trap.
--
-- Known limitation: a type reachable only transitively (defined in a module
-- neither this module nor its own local unions know about directly) is not
-- resolvable here and fails closed via OpaqueType, even if it would
-- structurally be fine. Not attempting a full transitive interface closure
-- for this first version -- see the plan doc.
resolveUnion :: Ctx -> ModuleName.Canonical -> Name.Name -> Maybe Can.Union
resolveUnion (Ctx home localUnions ifaces) tipeHome name =
  if tipeHome == home then
    Map.lookup name localUnions
  else
    case Map.lookup (ModuleName._module tipeHome) ifaces of
      Nothing ->
        Nothing

      Just iface ->
        case Map.lookup name (I._unions iface) of
          Just (I.OpenUnion union) -> Just union
          Just (I.ClosedUnion _)   -> Nothing
          Just (I.PrivateUnion _)  -> Nothing
          Nothing                  -> Nothing
