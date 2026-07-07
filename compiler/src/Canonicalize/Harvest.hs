{-# LANGUAGE OverloadedStrings #-}
module Canonicalize.Harvest
  ( Failure(..)
  , harvest
  )
  where


import Control.Monad (foldM)
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Data.Map.Strict ((!))
import qualified Data.Name as Name
import qualified Data.NonEmptyList as NE
import qualified Data.OneOrMore as OneOrMore

import qualified AST.Canonical as Can
import qualified AST.Source as Src
import qualified Canonicalize.Environment as Env
import qualified Canonicalize.Environment.Foreign as Foreign
import qualified Canonicalize.Environment.Local as Local
import qualified Canonicalize.Module as CModule
import qualified Canonicalize.Type as Type
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as CError
import qualified Reporting.Result as Result



-- FAILURE
--
-- harvest's own cycle-shaped checks are reported as plain data, not
-- Canonicalize.Error, since they span multiple modules and
-- Canonicalize.Error is scoped to rendering against one module's
-- source. The caller (Build.hs, in a follow-up plan) turns these into
-- Exit.BP_CycleMissingAnnotation / a type-alias-cycle equivalent;
-- CanonicalizeError below is for genuinely per-module problems (a
-- malformed signature, an unbound type variable, etc.) surfaced while
-- resolving one member's types/signatures, which do render against
-- that one member's own source the normal way.
data Failure
  = MissingAnnotation ModuleName.Raw Name.Name
  | AliasCycle (ModuleName.Raw, Name.Name) [(ModuleName.Raw, Name.Name)]
  | CanonicalizeError ModuleName.Raw CError.Error



-- TYPE REGISTRATION
--
-- Registration table: every SCC member's own union/alias name, arity,
-- and owning module -- built with no bodies resolved yet, exactly like
-- Local.addTypes registers a module's own type names before resolving
-- any of them. Aliases are also registered here (for arity/lookup
-- purposes) even though a *cyclic* alias is always rejected in Step 5
-- -- an acyclic alias that merely lives in a cyclic-SCC module (e.g.
-- `type alias Pair = (A.Foo, Int)` where only Foo, not Pair, is part of
-- the cycle) is completely fine and still needs registering here.


data TypeShape
  = ShapeUnion Int
  | ShapeAlias Int


type Registry = Map.Map (ModuleName.Raw, Name.Name) TypeShape


registerTypes :: Map.Map ModuleName.Raw Src.Module -> Registry
registerTypes modules =
  Map.foldrWithKey addModule Map.empty modules
  where
    addModule modName (Src.Module _ _ _ _ _ unions aliases _ _) registry =
      let
        addUnion r (A.At _ (Src.Union (A.At _ name) args _)) =
          Map.insert (modName, name) (ShapeUnion (length args)) r
        addAlias r (A.At _ (Src.Alias (A.At _ name) args _)) =
          Map.insert (modName, name) (ShapeAlias (length args)) r
      in
      foldl addAlias (foldl addUnion registry unions) aliases



-- BUILD ENV
--
-- Build one SCC member's Env for resolving its own union/alias bodies
-- and signatures. It sees three groups of type names:
--
--   * outside-the-SCC imports, via the real Foreign.createInitialEnv;
--   * every *other* SCC member's registered (name, arity), injected as
--     if they were foreign qualified bindings (addPeerImport); and
--   * this module's *own* registered (name, arity), injected unqualified
--     (addOwnTypes) -- mirroring Local.addTypes, which puts a module's
--     own type names into its env before any body/signature resolves.
--
-- Peers are deliberately not routed through Foreign.createInitialEnv --
-- that function requires a real, finished I.Interface (real
-- Can.Union/Can.Alias values, since it also builds constructor
-- bindings), which peers don't have yet at registration time. And any
-- import whose module isn't among the provided outside interfaces (a
-- default import like Basics/List when the caller supplies no core
-- interfaces) is dropped rather than passed to createInitialEnv, which
-- indexes ifaces with a partial (!) and would otherwise crash. In the
-- real build every used import has an interface, so nothing gets
-- dropped there; harvest only resolves types, so an unused missing
-- import is irrelevant, and a *used* missing type still surfaces as a
-- clean NotFoundType rather than a Prelude error.
buildEnv
  :: Registry
  -> Map.Map ModuleName.Raw I.Interface
  -> ModuleName.Raw
  -> Src.Module
  -> Result.Result i w CError.Error Env.Env
buildEnv registry outsideIfaces modName (Src.Module _ _ _ imports _ _ _ _ _) =
  let
    home = ModuleName.Canonical Pkg.dummyName modName
    isPeerImport (Src.Import (A.At _ n) _ _) =
      n /= modName && any (\(m, _) -> m == n) (Map.keys registry)
    isOutsideImport (Src.Import (A.At _ n) _ _) =
      Map.member n outsideIfaces
    outsideImports = filter isOutsideImport imports
    peerImports = filter isPeerImport imports
  in
  do  env <- Foreign.createInitialEnv home outsideIfaces outsideImports
      Result.ok $
        addOwnTypes registry modName $
          foldr (addPeerImport registry) env peerImports


-- Turn a registered (name, arity) into the Env.Type a use site resolves
-- against. Env.Alias's args/tipe fields are only consulted when a use
-- site *expands* the alias (Type.canonicalize's alias-arg substitution);
-- at registration time nothing should be expanding a peer/own alias yet,
-- so a placeholder body is safe here. (A signature referencing an
-- acyclic alias would read this placeholder -- see the module's harvest
-- note; v1's tested surface is unions plus alias-cycle rejection.)
shapeToType :: ModuleName.Canonical -> TypeShape -> Env.Type
shapeToType h shape =
  case shape of
    ShapeUnion arity -> Env.Union arity h
    ShapeAlias arity -> Env.Alias arity h [] (Can.TVar "harvestPlaceholder")


-- Insert this module's own registered types (unqualified) into its env.
addOwnTypes :: Registry -> ModuleName.Raw -> Env.Env -> Env.Env
addOwnTypes registry modName (Env.Env home vs ts cs bs qvs qts qcs) =
  let
    ownTypes =
      Map.fromList
        [ (name, Env.Specific home (shapeToType home shape))
        | ((m, name), shape) <- Map.toList registry
        , m == modName
        ]
  in
  Env.Env home vs (Map.union ownTypes ts) cs bs qvs qts qcs


-- Inject a peer SCC member's registered types under its import prefix
-- (its alias if it has one, else its module name), so a qualified
-- reference like `B.Stmt` resolves via the qualified-types table.
addPeerImport :: Registry -> Src.Import -> Env.Env -> Env.Env
addPeerImport registry (Src.Import (A.At _ peerName) maybeAlias _) (Env.Env home vs ts cs bs qvs qts qcs) =
  let
    prefix = maybe peerName id maybeAlias
    peerHome = ModuleName.Canonical Pkg.dummyName peerName
    peerTypes =
      Map.fromList
        [ (name, Env.Specific peerHome (shapeToType peerHome shape))
        | ((m, name), shape) <- Map.toList registry
        , m == peerName
        ]
  in
  Env.Env home vs ts cs bs qvs (Map.insertWith (Map.unionWith Env.mergeInfo) prefix peerTypes qts) qcs



-- RESOLVE TYPE BODIES
--
-- Resolve every SCC member's real union/alias bodies, using the envs
-- from buildEnv (which can already see every peer's and its own
-- registered name+arity). Rejects a type-alias cycle across the SCC
-- boundary first, the same way Local.addAliases rejects one within a
-- single module -- generalized from Name.Name keys to (ModuleName.Raw,
-- Name.Name) keys spanning every SCC member's aliases at once.


resolveTypeBodies
  :: Registry
  -> Map.Map ModuleName.Raw Env.Env
  -> Map.Map ModuleName.Raw Src.Module
  -> Either Failure (Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias))
resolveTypeBodies registry envs modules =
  case CModule.findCyclicKeys (aliasNodes registry modules) of
    Just (NE.List key keys) ->
      Left (AliasCycle key keys)

    Nothing ->
      Map.traverseWithKey (resolveOneModule envs) modules


resolveOneModule
  :: Map.Map ModuleName.Raw Env.Env
  -> ModuleName.Raw
  -> Src.Module
  -> Either Failure (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias)
resolveOneModule envs modName (Src.Module _ _ _ _ _ unions aliases _ _) =
  do  let env = envs ! modName
      unionList <- traverse (resolveDecl modName (fmap fst . Local.canonicalizeUnion env)) unions
      aliasList <- traverse (resolveDecl modName (fmap fst . Local.canonicalizeAlias env)) aliases
      Right (Map.fromList unionList, Map.fromList aliasList)


resolveDecl :: ModuleName.Raw -> (decl -> Result.Result () [w] CError.Error a) -> decl -> Either Failure a
resolveDecl modName resolver decl =
  case resultToEither (resolver decl) of
    Left err -> Left (CanonicalizeError modName err)
    Right a  -> Right a



-- ALIAS CYCLE GRAPH
--
-- One SCC-wide alias dependency graph, generalizing Local.hs's
-- toNode/getEdges from same-module-only edges to edges that can point
-- at a fellow SCC member too. TType is an unqualified reference (could
-- be same-module); TTypeQual is a `Prefix.Name` qualified reference,
-- resolved back to a real module via that module's own import list
-- (importAliases). Either way, an edge is only recorded if it actually
-- lands on a name in `registry` -- anything else (a builtin, an
-- outside-the-SCC import) is irrelevant to whether *this* SCC has a
-- cycle and is silently ignored, exactly like Local.hs's getEdges
-- ignores non-local names today.


-- findCyclicKeys (Canonicalize.Module) uses each node's payload as its
-- own key, so the node payload here IS the (module, name) key -- the
-- Src.Alias itself isn't needed once the edges are computed.
aliasNodes
  :: Registry
  -> Map.Map ModuleName.Raw Src.Module
  -> [((ModuleName.Raw, Name.Name), (ModuleName.Raw, Name.Name), [(ModuleName.Raw, Name.Name)])]
aliasNodes registry modules =
  concatMap toNodes (Map.toList modules)
  where
    toNodes (modName, modul@(Src.Module _ _ _ _ _ _ aliases _ _)) =
      let prefixes = importAliases modul in
      [ ( (modName, name)
        , (modName, name)
        , getEdgesAcrossModules registry prefixes modName [] tipe
        )
      | A.At _ (Src.Alias (A.At _ name) _ tipe) <- aliases
      ]


importAliases :: Src.Module -> Map.Map Name.Name ModuleName.Raw
importAliases (Src.Module _ _ _ imports _ _ _ _ _) =
  Map.fromList [ (maybe name id maybeAlias, name) | Src.Import (A.At _ name) maybeAlias _ <- imports ]


getEdgesAcrossModules
  :: Registry
  -> Map.Map Name.Name ModuleName.Raw
  -> ModuleName.Raw
  -> [(ModuleName.Raw, Name.Name)]
  -> Src.Type
  -> [(ModuleName.Raw, Name.Name)]
getEdgesAcrossModules registry prefixes home edges (A.At _ tipe) =
  let recur = getEdgesAcrossModules registry prefixes home in
  case tipe of
    Src.TLambda arg result ->
      recur (recur edges arg) result

    Src.TVar _ ->
      edges

    Src.TType _ name args ->
      let edges1 = if Map.member (home, name) registry then (home, name) : edges else edges in
      List.foldl' recur edges1 args

    Src.TTypeQual _ prefix name args ->
      let
        edges1 =
          case Map.lookup prefix prefixes of
            Just modName | Map.member (modName, name) registry -> (modName, name) : edges
            _ -> edges
      in
      List.foldl' recur edges1 args

    Src.TRecord fields _ ->
      List.foldl' (\es (_,t) -> recur es t) edges fields

    Src.TUnit ->
      edges

    Src.TTuple a b cs ->
      List.foldl' recur (recur (recur edges a) b) cs



-- HARVEST


harvest
  :: Pkg.Name
  -> Map.Map ModuleName.Raw I.Interface
  -> Map.Map ModuleName.Raw Src.Module
  -> Either Failure (Map.Map ModuleName.Raw I.Interface)
harvest pkg outsideIfaces modules =
  do  let registry = registerTypes modules
      envs <- Map.traverseWithKey (buildEnvFor registry outsideIfaces) modules
      typeBodies <- resolveTypeBodies registry envs modules
      Map.traverseWithKey (harvestOne pkg envs typeBodies) modules


buildEnvFor
  :: Registry
  -> Map.Map ModuleName.Raw I.Interface
  -> ModuleName.Raw
  -> Src.Module
  -> Either Failure Env.Env
buildEnvFor registry outsideIfaces modName modul =
  resolveDecl modName (const (buildEnv registry outsideIfaces modName modul)) ()


harvestOne
  :: Pkg.Name
  -> Map.Map ModuleName.Raw Env.Env
  -> Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias)
  -> ModuleName.Raw
  -> Src.Module
  -> Either Failure I.Interface
harvestOne pkg envs typeBodies modName (Src.Module _ exports _ _ values _ _ _ _) =
  do  let env = envs ! modName
      let (unions, aliases) = typeBodies ! modName
      annotations <- foldM (harvestSignature modName env) Map.empty values
      cexports <- either (Left . CanonicalizeError modName) Right $
        resultToEither (CModule.canonicalizeExports values unions aliases Map.empty Can.NoEffects exports)
      Right (I.fromHarvest pkg cexports unions aliases annotations)


harvestSignature
  :: ModuleName.Raw
  -> Env.Env
  -> Map.Map Name.Name Can.Annotation
  -> A.Located Src.Value
  -> Either Failure (Map.Map Name.Name Can.Annotation)
harvestSignature modName env acc (A.At _ (Src.Value (A.At _ name) _ _ maybeType)) =
  case maybeType of
    Nothing ->
      -- v1 restriction: every value is required to carry an explicit
      -- annotation while its module is part of a cyclic SCC, whether
      -- or not it's actually exposed. The exposed-only check happens
      -- naturally at the Interface-restriction step (I.fromHarvest /
      -- `restrict`): an unexposed value missing here just never
      -- surfaces to peers. Reject eagerly anyway so the error points at
      -- the actual missing annotation instead of a confusing later
      -- "not found".
      Left (MissingAnnotation modName name)

    Just srcType ->
      case resultToEither (Type.toAnnotation env srcType) of
        Left err   -> Left (CanonicalizeError modName err)
        Right ann  -> Right (Map.insert name ann acc)


-- Result.run's real signature (Reporting/Result.hs) is
-- `Result () [w] e a -> ([w], Either (OneOrMore.OneOrMore e) a)`. The
-- Left case is a *nonempty bag* of errors, not a single one -- reduce
-- to one representative error via OneOrMore.destruct (first wins),
-- consistent with how findCyclicKeys/AliasCycle above already report
-- only the first offending thing found rather than everything at once.
resultToEither :: Result.Result () [w] e a -> Either e a
resultToEither result =
  case snd (Result.run result) of
    Right a -> Right a
    Left oneOrMore -> Left (OneOrMore.destruct (\e _ -> e) oneOrMore)
