{-# LANGUAGE OverloadedStrings #-}
module Canonicalize.CycleCheck
  ( findCrossModuleValueCycle
  )
  where


import qualified Data.Map.Strict as Map
import qualified Data.Name as Name
import qualified Data.NonEmptyList as NE
import qualified Data.Set as Set

import qualified AST.Canonical as Can
import qualified Canonicalize.Module as CModule
import qualified Elm.ModuleName as ModuleName
import qualified Reporting.Annotation as A



-- FIND CROSS-MODULE VALUE CYCLE
--
-- Pass B (see docs/superpowers/specs/2026-07-07-cyclic-modules-design.md)
-- compiles every member of a cyclic SCC against Canonicalize.Harvest's
-- stub Interfaces, so a genuine non-terminating cross-module CAF cycle
-- (`A.x = B.y + 1`, `B.y = A.x - 1`) compiles cleanly through Pass B --
-- nothing in one module's own Compile.compile call can see a peer's
-- body, so the intra-module RecursiveDecl check
-- (Canonicalize.Module.detectBadCycles) never fires for it. This is the
-- post-check that closes that gap: once every SCC member has a real,
-- finished Can.Module, re-walk each argless top-level def's body for
-- direct (non-lambda-deferred) references to a *fellow SCC member's*
-- argless top-level def, and reject if that graph has a cycle -- the
-- exact same rule Canonicalize.Module already applies within one
-- module, generalized across the module boundary.
findCrossModuleValueCycle :: Map.Map ModuleName.Raw Can.Module -> Maybe (NE.List (ModuleName.Raw, Name.Name))
findCrossModuleValueCycle modules =
  let arglessNames = Set.fromList (concatMap (uncurry arglessDefNames) (Map.toList modules)) in
  CModule.findCyclicKeys (concatMap (uncurry (toNodes arglessNames)) (Map.toList modules))


-- Every top-level def with zero arguments, tagged with its owning
-- module -- the only defs that can ever participate in a real value
-- cycle (a function's invocation is always deferred, so a function can
-- never be the *source* of a direct edge -- see toNodes below, which
-- only ever builds edges out of an argless def's own body).
arglessDefNames :: ModuleName.Raw -> Can.Module -> [(ModuleName.Raw, Name.Name)]
arglessDefNames modName (Can.Module _ _ _ decls _ _ _ _) =
  [ (modName, name) | def <- flattenDecls decls, (name, 0, _) <- [defInfo def] ]


flattenDecls :: Can.Decls -> [Can.Def]
flattenDecls decls =
  case decls of
    Can.Declare def rest ->
      def : flattenDecls rest

    Can.DeclareRec def defs rest ->
      def : defs ++ flattenDecls rest

    Can.SaveTheEnvironment ->
      []


defInfo :: Can.Def -> (Name.Name, Int, Can.Expr)
defInfo def =
  case def of
    Can.Def (A.At _ name) args body ->
      (name, length args, body)

    Can.TypedDef (A.At _ name) _ args body _ ->
      (name, length args, body)


-- One graph node per argless def in modName, edge = a direct reference
-- (from that def's own body) to another argless def that is *also* a
-- member of this SCC (arglessNames) -- a reference to a function, or to
-- anything outside the SCC, is deliberately not a candidate edge here,
-- mirroring Canonicalize.Module's toNodeTwo/addDirects, which only ever
-- records an edge from an argless def and only cares whether the
-- reference is direct, not what kind of thing it targets (a target
-- that isn't itself an argless SCC def just never appears as its own
-- node, so it can't be part of any cycle Data.Graph.stronglyConnComp
-- finds -- same reasoning Build.hs's own crawl-graph relies on for
-- SForeign/SBadImport nodes never joining a CyclicSCC).
toNodes
  :: Set.Set (ModuleName.Raw, Name.Name)
  -> ModuleName.Raw
  -> Can.Module
  -> [((ModuleName.Raw, Name.Name), (ModuleName.Raw, Name.Name), [(ModuleName.Raw, Name.Name)])]
toNodes arglessNames modName (Can.Module _ _ _ decls _ _ _ _) =
  [ ((modName, name), (modName, name), Set.toList (Set.fromList (collectDirectRefs arglessNames modName False body)))
  | def <- flattenDecls decls
  , (name, 0, body) <- [defInfo def]
  ]


-- Walk a Can.Expr collecting every direct reference (VarTopLevel *or*
-- VarForeign) that lands on a fellow SCC member's argless def.
-- "Direct" means: not underneath a Lambda, and not underneath the body
-- of a locally let-bound function (nonzero args) -- see this module's
-- header comment for exactly which two Canonicalize.Expression call
-- sites this mirrors. A single sticky "underLambda" flag, set (and
-- never unset) on entering either of those two, correctly reproduces
-- the same direct/delayed distinction Elm's own intra-module cycle
-- check already relies on.
--
-- VarTopLevel is a same-module reference, so it needs the *walked*
-- module's own name (modName, threaded down from toNodes) to be tagged
-- as (modName, name) and checked against sccArgless -- otherwise a
-- same-module reference used as a relay hop inside a longer
-- cross-module cycle (A.x = A.y, A.y = B.z, B.z = A.x) is invisible to
-- this walker, even though Canonicalize.Module's own intra-module
-- check never sees the foreign edges needed to catch that chain
-- either. Pass B's own per-module cycle check only rejects a cycle
-- closed *entirely* within one module; it is blind to this case.
collectDirectRefs :: Set.Set (ModuleName.Raw, Name.Name) -> ModuleName.Raw -> Bool -> Can.Expr -> [(ModuleName.Raw, Name.Name)]
collectDirectRefs sccArgless modName underLambda (A.At _ expr) =
  let recur = collectDirectRefs sccArgless modName underLambda in
  case expr of
    Can.VarLocal _ ->
      []

    Can.VarTopLevel _ name ->
      if not underLambda && Set.member (modName, name) sccArgless
      then [(modName, name)]
      else []

    Can.VarForeign (ModuleName.Canonical _ foreignMod) name _annotation ->
      if not underLambda && Set.member (foreignMod, name) sccArgless
      then [(foreignMod, name)]
      else []

    Can.VarKernel _ _ ->
      []

    Can.VarCtor _ _ _ _ _ ->
      []

    Can.VarDebug _ _ _ ->
      []

    Can.VarOperator _ _ _ _ ->
      []

    Can.Chr _ -> []
    Can.Str _ -> []
    Can.Int _ -> []
    Can.Float _ -> []

    Can.List es ->
      concatMap recur es

    Can.Negate e ->
      recur e

    Can.Binop _ _ _ _ left right ->
      recur left ++ recur right

    Can.Lambda _ body ->
      collectDirectRefs sccArgless modName True body

    Can.Call func args ->
      recur func ++ concatMap recur args

    Can.If branches final ->
      concatMap (\(cond, branch) -> recur cond ++ recur branch) branches ++ recur final

    Can.Let def body ->
      collectDirectRefsDef sccArgless modName underLambda def ++ recur body

    Can.LetRec defs body ->
      concatMap (collectDirectRefsDef sccArgless modName underLambda) defs ++ recur body

    Can.LetDestruct _ e body ->
      recur e ++ recur body

    Can.Case e branches ->
      recur e ++ concatMap (\(Can.CaseBranch _ b) -> recur b) branches

    Can.Accessor _ ->
      []

    Can.Access e _ ->
      recur e

    Can.Update _ e fields ->
      recur e ++ concatMap (\(Can.FieldUpdate _ fe) -> recur fe) (Map.elems fields)

    Can.Record fields ->
      concatMap recur (Map.elems fields)

    Can.Unit ->
      []

    Can.Tuple a b mc ->
      recur a ++ recur b ++ maybe [] recur mc

    Can.Shader _ _ ->
      []


collectDirectRefsDef :: Set.Set (ModuleName.Raw, Name.Name) -> ModuleName.Raw -> Bool -> Can.Def -> [(ModuleName.Raw, Name.Name)]
collectDirectRefsDef sccArgless modName underLambda def =
  let (_, arity, body) = defInfo def in
  collectDirectRefs sccArgless modName (underLambda || arity > 0) body
