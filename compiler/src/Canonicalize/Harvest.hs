{-# LANGUAGE OverloadedStrings #-}
module Canonicalize.Harvest
  ( Failure(..)
  , Restriction(..)
  , harvest
  )
  where


import Control.Monad (foldM)
import qualified Data.Graph as Graph
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
  | UnsupportedInCycle ModuleName.Raw Restriction


-- A cyclic SCC module using any of these features is rejected outright
-- (see the plan's Global Constraints). Ports and effect managers are
-- rejected because this plan's harvested Interface has no
-- representation for them -- I.fromHarvest always produces
-- Can.NoEffects and no binops (see harvestOne), so a port/manager would
-- otherwise just silently vanish from the harvested Interface instead
-- of erroring. Custom infix operators are rejected because fixity /
-- associativity resolution isn't reproduced by this pass.
data Restriction
  = RestrictedPort
  | RestrictedEffectManager
  | RestrictedCustomOperator



-- REJECT PORTS / EFFECTS / CUSTOM OPERATORS
--
-- Checked explicitly, before any other harvest work, so an offending
-- module produces a clear Left naming itself and the violated
-- restriction, rather than harvestOne silently dropping its
-- binops/effects when building the stub Interface.
checkRestrictions :: Map.Map ModuleName.Raw Src.Module -> Either Failure ()
checkRestrictions modules =
  Map.foldrWithKey (\modName modul acc -> checkOne modName modul >> acc) (Right ()) modules


checkOne :: ModuleName.Raw -> Src.Module -> Either Failure ()
checkOne modName (Src.Module _ _ _ _ _ _ _ binops effects) =
  case effects of
    Src.Ports _ ->
      Left (UnsupportedInCycle modName RestrictedPort)

    Src.Manager _ _ ->
      Left (UnsupportedInCycle modName RestrictedEffectManager)

    Src.NoEffects ->
      if null binops then
        Right ()
      else
        Left (UnsupportedInCycle modName RestrictedCustomOperator)



-- TYPE REGISTRATION
--
-- Registration table: every SCC member's own union/alias name, arity,
-- and owning module -- built with no bodies resolved yet, exactly like
-- Local.addTypes registers a module's own type names before resolving
-- any of them. Aliases are also registered here (for arity/lookup
-- purposes) even though a *cyclic* alias is always rejected below -- an
-- acyclic alias that merely lives in a cyclic-SCC module (e.g. `type
-- alias Pair = (A.Foo, Int)` where only Foo, not Pair, is part of the
-- cycle) is completely fine and still needs registering here.
--
-- A union's entry here is always the *complete* picture -- Env.Union
-- only ever carries an arity and a home, never a body, so there's no
-- staged-resolution concern for a reference *to* a union (only for a
-- reference to an alias, whose Env.Alias entry does carry a body that
-- can be a not-yet-resolved placeholder -- see typeForShape below).


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



-- BASE ENVS
--
-- One SCC member's Env covering only what's *outside* the SCC: real
-- Foreign.createInitialEnv fed only the imports whose module has a
-- supplied outside interface. A peer import (naming a fellow SCC
-- member) is never in outsideIfaces, so filtering to isOutsideImport
-- alone already excludes every peer import -- Foreign.createInitialEnv
-- indexes ifaces with a partial (!) and would otherwise crash on a
-- default import like Basics/List when the caller supplies no core
-- interfaces, or on a peer. In the real build every used outside import
-- has an interface, so nothing gets dropped there; harvest only
-- resolves types, so an unused missing import is irrelevant, and a
-- *used* missing type still surfaces as a clean NotFoundType rather
-- than a Prelude error.
--
-- SCC-internal types (this module's own, and every peer's) are
-- deliberately NOT added here -- that's withSccTypes's job below, and
-- it needs to be re-run at different points with different amounts of
-- alias-body information available (see the two-phase resolution
-- section), so baking a fixed snapshot of SCC types into the env at
-- this stage would be wrong.
buildEnv
  :: Pkg.Name
  -> Map.Map ModuleName.Raw I.Interface
  -> ModuleName.Raw
  -> Src.Module
  -> Result.Result i w CError.Error Env.Env
buildEnv pkg outsideIfaces modName (Src.Module _ _ _ imports _ _ _ _ _) =
  let
    home = ModuleName.Canonical pkg modName
    isOutsideImport (Src.Import (A.At _ n) _ _) =
      Map.member n outsideIfaces
    outsideImports = filter isOutsideImport imports
  in
  Foreign.createInitialEnv home outsideIfaces outsideImports



-- SCC TYPES -- STAGE-AWARE INJECTION
--
-- Turn a registered (name, arity) into the Env.Type a use site resolves
-- against, given whatever subset of the SCC's aliases has a real
-- resolved body *so far* (`resolvedAliases`). A union is always
-- complete (see the TYPE REGISTRATION note above). An alias not yet
-- present in `resolvedAliases` gets a placeholder body -- safe as long
-- as nothing ever actually reads that placeholder, which the
-- topological ordering in resolveAliasesInOrder below guarantees: an
-- alias is only resolved after everything its own body references is
-- already in `resolvedAliases`, so by the time any *use site* (another
-- alias, a union, or a signature) can legitimately read a given alias's
-- body, that alias is guaranteed to already be in `resolvedAliases`.
typeForShape
  :: Map.Map (ModuleName.Raw, Name.Name) Can.Alias
  -> ModuleName.Canonical
  -> (ModuleName.Raw, Name.Name)
  -> TypeShape
  -> Env.Type
typeForShape resolvedAliases home key shape =
  case shape of
    ShapeUnion arity ->
      Env.Union arity home

    ShapeAlias arity ->
      case Map.lookup key resolvedAliases of
        Just (Can.Alias vars tipe) -> Env.Alias arity home vars tipe
        Nothing                    -> Env.Alias arity home [] (Can.TVar "harvestPlaceholder")


-- Every type (name, arity/body) registered as belonging to one SCC
-- module, keyed unqualified -- used both to inject a module's own types
-- (unqualified) and a peer's types (qualified, under whatever prefix
-- imports it). Tags every produced Env.Type's home with the real `pkg`
-- (matching Canonicalize.Module's real `home = ModuleName.Canonical pkg
-- (Src.getName modul)`) rather than Pkg.dummyName -- for a package
-- project (not an application), pkg is a real published package name,
-- and a harvested type body must embed the exact same
-- ModuleName.Canonical a real compile would, or later unification sees
-- a mismatch between (dummyName, A) and (realPkg, A) for what's
-- supposed to be the same type.
sccTypesFor :: Pkg.Name -> Registry -> Map.Map (ModuleName.Raw, Name.Name) Can.Alias -> ModuleName.Raw -> Env.Exposed Env.Type
sccTypesFor pkg registry resolvedAliases modName =
  let home = ModuleName.Canonical pkg modName in
  Map.fromList
    [ (name, Env.Specific home (typeForShape resolvedAliases home (m, name) shape))
    | ((m, name), shape) <- Map.toList registry
    , m == modName
    ]


-- Inject a peer SCC member's types under its import prefix (its alias
-- if it has one, else its module name), so a qualified reference like
-- `B.Stmt` resolves via the qualified-types table. Merges via
-- Map.insertWith (Map.unionWith Env.mergeInfo), matching the exact
-- convention Foreign.hs's addQualified already uses for building a
-- qualified-types table from outside imports -- not a wholesale replace,
-- since two different peer imports could in principle share a prefix
-- (e.g. two peers both aliased `as X`) and should merge, not clobber.
addPeerTypes
  :: Pkg.Name
  -> Registry
  -> Map.Map (ModuleName.Raw, Name.Name) Can.Alias
  -> Src.Import
  -> Env.Qualified Env.Type
  -> Env.Qualified Env.Type
addPeerTypes pkg registry resolvedAliases (Src.Import (A.At _ peerName) maybeAlias _) qts =
  let
    prefix = maybe peerName id maybeAlias
    peerTypes = sccTypesFor pkg registry resolvedAliases peerName
  in
  Map.insertWith (Map.unionWith Env.mergeInfo) prefix peerTypes qts


-- Names exposed unqualified by a peer import's own `exposing` clause,
-- mirroring how Foreign.hs's addExposedValue (the Src.Upper / Public|
-- Private case) handles a type-exposing list for an *outside* import.
-- Peer imports never reach Foreign.createInitialEnv at all (see BASE
-- ENVS above -- that's the only place an exposing list otherwise gets
-- honored), so without this, `import B exposing (Stmt)` used to bring
-- in only the qualified `B.Stmt` form; bare `Stmt` would fail to
-- resolve even though it's at least as common an idiom as the qualified
-- form. harvest never builds Env.Ctor entries at all (it only resolves
-- types/signatures, not values' bodies), so there's no ctor-exposing
-- counterpart needed here the way Foreign.hs has one.
peerExposedTypes
  :: Pkg.Name
  -> Registry
  -> Map.Map (ModuleName.Raw, Name.Name) Can.Alias
  -> Src.Import
  -> Env.Exposed Env.Type
peerExposedTypes pkg registry resolvedAliases (Src.Import (A.At _ peerName) _ exposing) =
  let peerTypes = sccTypesFor pkg registry resolvedAliases peerName in
  case exposing of
    Src.Open ->
      peerTypes

    Src.Explicit exposedList ->
      Map.fromList
        [ (name, info)
        | Src.Upper (A.At _ name) _ <- exposedList
        , Just info <- [Map.lookup name peerTypes]
        ]


-- Extend one module's base (outside-only) env with the SCC's own +
-- peer types, as of a given resolvedAliases snapshot. Called at
-- different points with different snapshots: partially-filled (mid-way
-- through resolveAliasesInOrder) and complete (resolving unions in
-- Phase B, and again for signature harvesting).
--
-- ts1's Map.union nesting gives ownTypes top priority, then whatever a
-- peer import's own exposing list brought in unqualified, then
-- whatever the base env already had (an outside import's own Open
-- exposing, e.g. Basics) -- "own name always wins" mirrors
-- Local.hs/addVars's own "use union to overwrite foreign stuff"
-- convention elsewhere in this codebase.
withSccTypes
  :: Pkg.Name
  -> Registry
  -> Map.Map (ModuleName.Raw, Name.Name) Can.Alias
  -> Map.Map ModuleName.Raw Src.Module
  -> ModuleName.Raw
  -> Env.Env
  -> Env.Env
withSccTypes pkg registry resolvedAliases modules modName (Env.Env home vs ts cs bs qvs qts qcs) =
  let
    Src.Module _ _ _ imports _ _ _ _ _ = modules ! modName
    ownTypes = sccTypesFor pkg registry resolvedAliases modName
    peerImports =
      [ imp | imp@(Src.Import (A.At _ n) _ _) <- imports, n /= modName, Map.member n modules ]
    peerExposed =
      foldr (Map.union . peerExposedTypes pkg registry resolvedAliases) Map.empty peerImports
    ts1 = Map.union ownTypes (Map.union peerExposed ts)
    qts1 = foldr (addPeerTypes pkg registry resolvedAliases) qts peerImports
  in
  Env.Env home vs ts1 cs bs qvs qts1 qcs



-- TWO-PHASE TYPE BODY RESOLUTION
--
-- Phase A resolves every SCC alias's real body, one at a time, in true
-- cross-module topological dependency order -- an order that exists
-- because a cyclic alias dependency (across or within modules) is
-- rejected up front by findCyclicKeys, before Phase A ever starts. Each
-- alias is resolved against an env built from whatever's been resolved
-- *so far*, and its result is folded into the running snapshot before
-- the next alias resolves -- this is a direct generalization of
-- Canonicalize.Environment.Local's own addAliases/addAlias
-- (Local.hs:120-145), which does the exact same "topologically-ordered
-- fold, each resolved alias visible to the next" for the single-module
-- case via Graph.stronglyConnComp + foldM. Only once every alias has a
-- real body does Phase B resolve every union -- unions never need
-- ordering among themselves (a union is never inlined into another
-- type, only an alias is), so Phase B builds each module's env once
-- from the complete, final alias-body snapshot and resolves all of that
-- module's unions in one pass, same shape as the original (pre-fix)
-- single-pass design.


-- One node per SCC alias, in the same shape aliasNodes already builds
-- for cycle detection (payload doubles as key, as findCyclicKeys
-- requires). Reused here for its ordering, not just its cycle check:
-- Graph.stronglyConnComp's output list order is exactly the order
-- Local.hs's own addAliases relies on (each SCC in the list has all its
-- dependencies already appearing earlier in the list). Since Phase A
-- only ever runs after findCyclicKeys has already confirmed this exact
-- edge set is acyclic, every SCC here is guaranteed AcyclicSCC; the
-- CyclicSCC arm is unreachable in practice and kept only so the match
-- is total.
topoAliasOrder :: Registry -> Map.Map ModuleName.Raw Src.Module -> [(ModuleName.Raw, Name.Name)]
topoAliasOrder registry modules =
  concatMap fromSCC (Graph.stronglyConnComp (aliasNodes registry modules))
  where
    fromSCC scc =
      case scc of
        Graph.AcyclicSCC key -> [key]
        Graph.CyclicSCC keys -> keys


buildAliasByKey :: Map.Map ModuleName.Raw Src.Module -> Map.Map (ModuleName.Raw, Name.Name) (A.Located Src.Alias)
buildAliasByKey modules =
  Map.fromList
    [ ((modName, name), alias)
    | (modName, Src.Module _ _ _ _ _ _ aliases _ _) <- Map.toList modules
    , alias@(A.At _ (Src.Alias (A.At _ name) _ _)) <- aliases
    ]


resolveAliasesInOrder
  :: Pkg.Name
  -> Registry
  -> Map.Map ModuleName.Raw Env.Env
  -> Map.Map ModuleName.Raw Src.Module
  -> Either Failure (Map.Map (ModuleName.Raw, Name.Name) Can.Alias)
resolveAliasesInOrder pkg registry baseEnvs modules =
  foldM resolveOne Map.empty (topoAliasOrder registry modules)
  where
    aliasByKey = buildAliasByKey modules

    resolveOne resolvedSoFar key@(modName, _) =
      do  let aliasNode = aliasByKey ! key
          let env = withSccTypes pkg registry resolvedSoFar modules modName (baseEnvs ! modName)
          (_, alias) <- resolveDecl modName (fmap fst . Local.canonicalizeAlias env) aliasNode
          Right (Map.insert key alias resolvedSoFar)


resolveUnions
  :: Pkg.Name
  -> Registry
  -> Map.Map (ModuleName.Raw, Name.Name) Can.Alias
  -> Map.Map ModuleName.Raw Env.Env
  -> Map.Map ModuleName.Raw Src.Module
  -> Either Failure (Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union))
resolveUnions pkg registry finalAliases baseEnvs modules =
  Map.traverseWithKey resolveOneModuleUnions modules
  where
    resolveOneModuleUnions modName (Src.Module _ _ _ _ _ unions _ _ _) =
      do  let env = withSccTypes pkg registry finalAliases modules modName (baseEnvs ! modName)
          unionList <- traverse (resolveDecl modName (fmap fst . Local.canonicalizeUnion env)) unions
          Right (Map.fromList unionList)


combineTypeBodies
  :: Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union)
  -> Map.Map (ModuleName.Raw, Name.Name) Can.Alias
  -> Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias)
combineTypeBodies unionsByModule finalAliases =
  Map.mapWithKey (\modName unions -> (unions, aliasesForModule modName)) unionsByModule
  where
    aliasesForModule modName =
      Map.fromList [ (name, alias) | ((m, name), alias) <- Map.toList finalAliases, m == modName ]


-- Resolve every SCC member's real union/alias bodies. Rejects a
-- type-alias cycle across the SCC boundary first, the same way
-- Local.addAliases rejects one within a single module -- generalized
-- from Name.Name keys to (ModuleName.Raw, Name.Name) keys spanning
-- every SCC member's aliases at once. Returns both the flat
-- cross-module alias-body map (reused directly by harvest to build the
-- final signature-harvesting envs) and the per-module (unions, aliases)
-- pairs that feed I.fromHarvest.
resolveTypeBodies
  :: Pkg.Name
  -> Registry
  -> Map.Map ModuleName.Raw Env.Env
  -> Map.Map ModuleName.Raw Src.Module
  -> Either Failure
       ( Map.Map (ModuleName.Raw, Name.Name) Can.Alias
       , Map.Map ModuleName.Raw (Map.Map Name.Name Can.Union, Map.Map Name.Name Can.Alias)
       )
resolveTypeBodies pkg registry baseEnvs modules =
  case CModule.findCyclicKeys (aliasNodes registry modules) of
    Just (NE.List key keys) ->
      Left (AliasCycle key keys)

    Nothing ->
      do  finalAliases <- resolveAliasesInOrder pkg registry baseEnvs modules
          unionsByModule <- resolveUnions pkg registry finalAliases baseEnvs modules
          Right (finalAliases, combineTypeBodies unionsByModule finalAliases)


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
-- ignores non-local names today. Also reused (via topoAliasOrder above)
-- for the topological order Phase A resolves aliases in -- the same
-- edge set answers both "is there a cycle" and "what order resolves
-- correctly", since both questions are about the same dependency graph.


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
  do  checkRestrictions modules
      let registry = registerTypes modules
      baseEnvs <- Map.traverseWithKey (buildBaseEnvFor pkg outsideIfaces) modules
      (finalAliases, typeBodies) <- resolveTypeBodies pkg registry baseEnvs modules
      let finalEnvs = Map.mapWithKey (\modName env -> withSccTypes pkg registry finalAliases modules modName env) baseEnvs
      Map.traverseWithKey (harvestOne pkg finalEnvs typeBodies) modules


buildBaseEnvFor
  :: Pkg.Name
  -> Map.Map ModuleName.Raw I.Interface
  -> ModuleName.Raw
  -> Src.Module
  -> Either Failure Env.Env
buildBaseEnvFor pkg outsideIfaces modName modul =
  resolveDecl modName (const (buildEnv pkg outsideIfaces modName modul)) ()


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
