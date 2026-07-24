{-# LANGUAGE OverloadedStrings #-}
module Generate.JavaScript
  ( generate
  , generateSplit
  , SplitError(..)
  , generateForRepl
  , generateForReplEndpoint
  )
  where


import Prelude hiding (cycle, print)
import qualified Data.ByteString.Builder as B
import qualified Data.List as List
import Data.Map ((!))
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Name as Name
import qualified Data.Set as Set
import qualified Data.Utf8 as Utf8

import qualified AST.Canonical as Can
import qualified AST.Optimized as Opt
import qualified Data.Index as Index
import qualified Elm.Kernel as K
import qualified Elm.ModuleName as ModuleName
import qualified Generate.JavaScript.Builder as JS
import qualified Generate.JavaScript.Expression as Expr
import qualified Generate.JavaScript.Functions as Functions
import qualified Generate.JavaScript.Name as JsName
import qualified Generate.Mode as Mode
import qualified Nitpick.WorkerRegistry as WorkerRegistry
import qualified Reporting.Doc as D
import qualified Reporting.Render.Type as RT
import qualified Reporting.Render.Type.Localizer as L



-- GENERATE


type Graph = Map.Map Opt.Global Opt.Node
type Mains = Map.Map ModuleName.Canonical Opt.Main


generate :: Mode.Mode -> Opt.GlobalGraph -> Mains -> B.Builder
generate mode globalGraph@(Opt.GlobalGraph graph _) mains =
  let
    state = Map.foldrWithKey (addMain mode graph) emptyState mains
    -- Only registers globals that actually made it into this bundle
    -- (_seenGlobals) -- WorkerRegistry.collect itself scans the whole
    -- merged program graph, which may include Worker.run call sites from
    -- modules unreachable from this build's own `mains`.
    workerTargets = Set.intersection (WorkerRegistry.collect globalGraph) (_seenGlobals state)
  in
  "(function(scope){\n'use strict';"
  <> Functions.functions
  <> perfNote mode
  <> stateToBuilder state
  <> generateWorkerRegistrations mode workerTargets
  <> toMainExports mode mains
  <> "}(this));"



-- GENERATE SPLIT
--
-- Compiles `mains` into a "core" bundle plus a separately-loadable "chunk"
-- bundle holding everything defined in `chunkHome`. The core pass never
-- recurses into chunkHome's own globals (see addGlobal's redirect branch),
-- so nothing from the chunk gets inlined into core even if something
-- reachable from `mains` calls into it directly. The chunk pass is an
-- entirely ordinary, self-contained generate-style DFS seeded from every
-- global chunkHome defines -- it duplicates whatever shared helpers/kernel
-- code it needs rather than importing anything from core (V1 doesn't
-- dedupe across the two bundles, only avoids inlining chunk code into
-- core). The only bridge is one-directional: once loaded, the chunk
-- assigns each global core referenced onto the shared global object
-- (`scope` at top level of a classic <script> tag == window), so core's
-- already-emitted, perfectly ordinary references to those (bare,
-- undeclared-in-core) identifiers resolve via normal JS scope-chain
-- lookup the moment that code path actually runs -- not necessarily at
-- core's own load time. See docs/superpowers/plans (code-splitting plan)
-- for the full design rationale, including why a naive "redirect via a
-- local alias var" design doesn't work (it would snapshot `undefined`
-- once at load time instead of resolving live at use time).


-- V1 deliberately does not dedupe shared helpers/kernel code between core
-- and the chunk (see module-level note above) -- so unlike an earlier
-- design draft, there is no "chunk needs kernel code core doesn't have"
-- error case: the chunk pass independently, fully resolves its own kernel
-- needs every time, same as any ordinary standalone `generate` call would.
newtype SplitError
  = ChunkModuleNotFound ModuleName.Canonical


generateSplit :: Mode.Mode -> Opt.GlobalGraph -> Mains -> ModuleName.Canonical -> Either SplitError (B.Builder, B.Builder)
generateSplit mode globalGraph@(Opt.GlobalGraph graph _) mains chunkHome =
  let
    chunkRoots = [ g | g@(Opt.Global home _) <- Map.keys graph, home == chunkHome ]
  in
  if null chunkRoots then
    Left (ChunkModuleNotFound chunkHome)
  else
    let
      coreSeedState = emptyState { _chunkHome = Just chunkHome }
      coreState = Map.foldrWithKey (addMain mode graph) coreSeedState mains
      boundary = _boundary coreState

      chunkState = List.foldl' (addGlobal mode graph) emptyState chunkRoots

      coreWorkerTargets = Set.intersection (WorkerRegistry.collect globalGraph) (_seenGlobals coreState)

      coreBuilder =
        "(function(scope){\n'use strict';"
        <> Functions.functions
        <> perfNote mode
        <> stateToBuilder coreState
        <> generateWorkerRegistrations mode coreWorkerTargets
        <> toMainExports mode mains
        <> "}(this));"

      chunkBuilder =
        "(function(scope){\n'use strict';"
        <> Functions.functions
        <> stateToBuilder chunkState
        <> chunkExports boundary
        <> "}(this));"
    in
    Right (coreBuilder, chunkBuilder)


chunkExports :: Set.Set Opt.Global -> B.Builder
chunkExports boundary =
  Set.foldr (\global acc -> exportOnScope global <> acc) mempty boundary


exportOnScope :: Opt.Global -> B.Builder
exportOnScope (Opt.Global home name) =
  let n = JsName.toBuilder (JsName.fromGlobal home name) in
  "scope." <> n <> " = " <> n <> ";"


-- WORKER REGISTRY
--
-- Emits one `_Worker_register(tag, fn)` call per top-level function ever
-- passed as a Worker.run target (see Optimize.Expression's buildWorkerRun),
-- so a Worker-side bootstrap running this same compiled bundle can dispatch
-- an incoming message to the right function by tag. No codecs to pass
-- anymore -- Worker.run hands the raw compiled value straight through
-- postMessage (see Nitpick.Worker's module comment). The tag is recomputed
-- here from the Global via JsName.workerTag, the same pure function
-- buildWorkerRun itself used to embed the matching Opt.Str literal at the
-- call site -- both sides derive it from nothing but (home, name), so they
-- can never drift apart.
generateWorkerRegistrations :: Mode.Mode -> Set.Set Opt.Global -> B.Builder
generateWorkerRegistrations mode targets =
  Set.foldr (\global acc -> registerStmt mode global <> acc) mempty targets


registerStmt :: Mode.Mode -> Opt.Global -> B.Builder
registerStmt mode global@(Opt.Global home name) =
  let
    registration =
      Opt.Call (Opt.VarKernel Name.worker "register")
        [ Opt.Str (JsName.workerTag home name)
        , Opt.VarGlobal global
        ]
  in
  JS.stmtToBuilder (JS.ExprStmt (Expr.codeToExpr (Expr.generate mode registration)))


addMain :: Mode.Mode -> Graph -> ModuleName.Canonical -> Opt.Main -> State -> State
addMain mode graph home _ state =
  addGlobal mode graph state (Opt.Global home "main")


perfNote :: Mode.Mode -> B.Builder
perfNote mode =
  case mode of
    Mode.Prod _ _ ->
      ""

    Mode.Dev Nothing ->
      "console.warn('Compiled in DEV mode. Follow the advice at "
      <> B.stringUtf8 (D.makeNakedLink "optimize")
      <> " for better performance and smaller assets.');"

    Mode.Dev (Just _) ->
      "console.warn('Compiled in DEBUG mode. Follow the advice at "
      <> B.stringUtf8 (D.makeNakedLink "optimize")
      <> " for better performance and smaller assets.');"



-- GENERATE FOR REPL


generateForRepl :: Bool -> L.Localizer -> Opt.GlobalGraph -> ModuleName.Canonical -> Name.Name -> Can.Annotation -> B.Builder
generateForRepl ansi localizer (Opt.GlobalGraph graph _) home name (Can.Forall _ tipe) =
  let
    mode = Mode.Dev Nothing
    debugState = addGlobal mode graph emptyState (Opt.Global ModuleName.debug "toString")
    evalState = addGlobal mode graph debugState (Opt.Global home name)
  in
  "process.on('uncaughtException', function(err) { process.stderr.write(err.toString() + '\\n'); process.exit(1); });"
  <> Functions.functions
  <> stateToBuilder evalState
  <> print ansi localizer home name tipe


print :: Bool -> L.Localizer -> ModuleName.Canonical -> Name.Name -> Can.Type -> B.Builder
print ansi localizer home name tipe =
  let
    value = JsName.toBuilder (JsName.fromGlobal home name)
    toString = JsName.toBuilder (JsName.fromKernel Name.debug "toAnsiString")
    tipeDoc = RT.canToDoc localizer RT.None tipe
    bool = if ansi then "true" else "false"
  in
  "var _value = " <> toString <> "(" <> bool <> ", " <> value <> ");\n\
  \var _type = " <> B.stringUtf8 (show (D.toString tipeDoc)) <> ";\n\
  \function _print(t) { console.log(_value + (" <> bool <> " ? '\x1b[90m' + t + '\x1b[0m' : t)); }\n\
  \if (_value.length + 3 + _type.length >= 80 || _type.indexOf('\\n') >= 0) {\n\
  \    _print('\\n    : ' + _type.split('\\n').join('\\n      '));\n\
  \} else {\n\
  \    _print(' : ' + _type);\n\
  \}\n"



-- GENERATE FOR REPL ENDPOINT


generateForReplEndpoint :: L.Localizer -> Opt.GlobalGraph -> ModuleName.Canonical -> Maybe Name.Name -> Can.Annotation -> B.Builder
generateForReplEndpoint localizer (Opt.GlobalGraph graph _) home maybeName (Can.Forall _ tipe) =
  let
    name = maybe Name.replValueToPrint id maybeName
    mode = Mode.Dev Nothing
    debugState = addGlobal mode graph emptyState (Opt.Global ModuleName.debug "toString")
    evalState = addGlobal mode graph debugState (Opt.Global home name)
  in
  Functions.functions
  <> stateToBuilder evalState
  <> postMessage localizer home maybeName tipe


postMessage :: L.Localizer -> ModuleName.Canonical -> Maybe Name.Name -> Can.Type -> B.Builder
postMessage localizer home maybeName tipe =
  let
    name = maybe Name.replValueToPrint id maybeName
    value = JsName.toBuilder (JsName.fromGlobal home name)
    toString = JsName.toBuilder (JsName.fromKernel Name.debug "toAnsiString")
    tipeDoc = RT.canToDoc localizer RT.None tipe
    toName n = "\"" <> Name.toBuilder n <> "\""
  in
  "self.postMessage({\n\
  \  name: " <> maybe "null" toName maybeName <> ",\n\
  \  value: " <> toString <> "(true, " <> value <> "),\n\
  \  type: " <> B.stringUtf8 (show (D.toString tipeDoc)) <> "\n\
  \});\n"



-- GRAPH TRAVERSAL STATE


data State =
  State
    { _revKernels :: [B.Builder]
    , _revBuilders :: [B.Builder]
    , _seenGlobals :: Set.Set Opt.Global
    -- The next two fields only matter for generateSplit's core pass (see
    -- below); for the ordinary generate/generateForRepl paths _chunkHome
    -- stays Nothing forever, so the redirect branch in addGlobal never
    -- fires and behavior is byte-identical to before code splitting existed.
    , _chunkHome :: Maybe ModuleName.Canonical
    , _boundary :: Set.Set Opt.Global
    }


emptyState :: State
emptyState =
  State mempty [] Set.empty Nothing Set.empty


stateToBuilder :: State -> B.Builder
stateToBuilder (State revKernels revBuilders _ _ _) =
  prependBuilders revKernels (prependBuilders revBuilders mempty)


prependBuilders :: [B.Builder] -> B.Builder -> B.Builder
prependBuilders revBuilders monolith =
  List.foldl' (\m b -> b <> m) monolith revBuilders



-- ADD DEPENDENCIES


addGlobal :: Mode.Mode -> Graph -> State -> Opt.Global -> State
addGlobal mode graph state global@(Opt.Global home _) =
  if Just home == _chunkHome state then
    -- This global belongs to the module carved out into a separate lazy
    -- chunk (see generateSplit). Do NOT recurse into its definition or
    -- deps here -- that would pull the chunk's code into this bundle,
    -- defeating the whole point of splitting it out. Just remember that
    -- something in this bundle references it; the reference itself
    -- (a bare JsName.fromGlobal identifier, emitted completely normally
    -- by whatever def is calling into it) resolves at *use time* via
    -- ordinary JS scope-chain lookup once the chunk has loaded and
    -- exported it onto the shared global object -- see generateSplit.
    state { _boundary = Set.insert global (_boundary state) }
  else if Set.member global (_seenGlobals state) then
    state
  else
    addGlobalHelp mode graph global $
      state { _seenGlobals = Set.insert global (_seenGlobals state) }


addGlobalHelp :: Mode.Mode -> Graph -> Opt.Global -> State -> State
addGlobalHelp mode graph global state =
  let
    addDeps deps someState =
      Set.foldl' (addGlobal mode graph) someState deps
  in
  case graph ! global of
    Opt.Define expr deps ->
      addMaybeStmt (Expr.generateUnwrapped mode global expr) $
        addStmt (addDeps deps state) (
          var global (Expr.generate mode expr)
        )

    Opt.DefineTailFunc argNames body deps ->
      addMaybeStmt (Expr.generateUnwrappedTail mode global argNames body) $
        addStmt (addDeps deps state) (
          let (Opt.Global _ name) = global in
          var global (Expr.generateTailDef mode name argNames body)
        )

    Opt.Ctor index arity maxArity ->
      addStmt state (
        var global (Expr.generateCtor mode global index arity maxArity)
      )

    Opt.Link linkedGlobal ->
      addGlobal mode graph state linkedGlobal

    Opt.Cycle names values functions deps ->
      addStmt (addDeps deps state) (
        generateCycle mode global names values functions
      )

    Opt.Manager effectsType ->
      generateManager mode graph global effectsType state

    Opt.Kernel chunks deps ->
      if isDebugger global && not (Mode.isDebug mode) then
        state
      else
        addKernel (addDeps deps state) (generateKernel mode chunks <> padListNil mode global)

    Opt.Enum index ->
      addStmt state (
        generateEnum mode global index
      )

    Opt.Box ->
      addStmt (addGlobal mode graph state identity) (
        generateBox mode global
      )

    Opt.PortIncoming decoder deps ->
      addStmt (addDeps deps state) (
        generatePort mode global "incomingPort" decoder
      )

    Opt.PortOutgoing encoder deps ->
      addStmt (addDeps deps state) (
        generatePort mode global "outgoingPort" encoder
      )


addStmt :: State -> JS.Stmt -> State
addStmt state stmt =
  addBuilder state (JS.stmtToBuilder stmt)


addMaybeStmt :: Maybe JS.Stmt -> State -> State
addMaybeStmt maybeStmt state =
  maybe state (addStmt state) maybeStmt


addBuilder :: State -> B.Builder -> State
addBuilder state builder =
  state { _revBuilders = builder : _revBuilders state }


addKernel :: State -> B.Builder -> State
addKernel state kernel =
  state { _revKernels = kernel : _revKernels state }


var :: Opt.Global -> Expr.Code -> JS.Stmt
var (Opt.Global home name) code =
  JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr code)


isDebugger :: Opt.Global -> Bool
isDebugger (Opt.Global (ModuleName.Canonical _ home) _) =
  home == Name.debugger


-- Reassigns elm/core's List.js "var _List_Nil = { $: 0 };" to Cons's
-- { $, a, b } shape so V8 sees one hidden class across Cons/Nil (see
-- docs/superpowers/specs/2026-07-18-kernel-list-shape-padding-design.md).
-- Relies on _List_Nil being declared with `var` earlier in the same
-- concatenated kernel text; a rename in elm/core would surface as a
-- ReferenceError at module load, not a silent no-op.
padListNil :: Mode.Mode -> Opt.Global -> B.Builder
padListNil mode global =
  case mode of
    Mode.Prod _ _ | global == Opt.toKernelGlobal "List" ->
      "_List_Nil = { $: 0, a: null, b: null };"
    _ ->
      mempty


-- GENERATE CYCLES


generateCycle :: Mode.Mode -> Opt.Global -> [Name.Name] -> [(Name.Name, Opt.Expr)] -> [Opt.Def] -> JS.Stmt
generateCycle mode (Opt.Global home _) names values functions =
  JS.Block
    [ JS.Block $ concatMap (generateCycleFunc mode home) functions
    , JS.Block $ map (generateSafeCycle mode home) values
    , case map (generateRealCycle home) values of
        [] ->
          JS.EmptyStmt

        realBlock@(_:_) ->
            case mode of
              Mode.Prod _ _ ->
                JS.Block realBlock

              Mode.Dev _ ->
                JS.Try (JS.Block realBlock) JsName.dollar $ JS.Throw $ JS.String $
                  "Some top-level definitions from `" <> Name.toBuilder (ModuleName._module home) <> "` are causing infinite recursion:\\n"
                  <> drawCycle names
                  <> "\\n\\nThese errors are very tricky, so read "
                  <> B.stringUtf8 (D.makeNakedLink "bad-recursion")
                  <> " to learn how to fix it!"
    ]


generateCycleFunc :: Mode.Mode -> ModuleName.Canonical -> Opt.Def -> [JS.Stmt]
generateCycleFunc mode home def =
  case def of
    Opt.Def name expr ->
      JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr (Expr.generate mode expr))
        : Maybe.maybeToList (Expr.generateUnwrapped mode (Opt.Global home name) expr)

    Opt.TailDef name args expr ->
      JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr (Expr.generateTailDef mode name args expr))
        : Maybe.maybeToList (Expr.generateUnwrappedTail mode (Opt.Global home name) args expr)

    Opt.TailDefCons consInfo holeIndex arity name args expr ->
      JS.Var (JsName.fromGlobal home name) (Expr.codeToExpr (Expr.generateTailDefCons mode consInfo holeIndex arity name args expr))
        : Maybe.maybeToList (Expr.generateUnwrappedTailCons mode consInfo holeIndex arity (Opt.Global home name) args expr)


generateSafeCycle :: Mode.Mode -> ModuleName.Canonical -> (Name.Name, Opt.Expr) -> JS.Stmt
generateSafeCycle mode home (name, expr) =
  JS.FunctionStmt (JsName.fromCycle home name) [] $
    Expr.codeToStmtList (Expr.generate mode expr)


generateRealCycle :: ModuleName.Canonical -> (Name.Name, expr) -> JS.Stmt
generateRealCycle home (name, _) =
  let
    safeName = JsName.fromCycle home name
    realName = JsName.fromGlobal home name
  in
  JS.Block
    [ JS.Var realName (JS.Call (JS.Ref safeName) [])
    , JS.ExprStmt $ JS.Assign (JS.LRef safeName) $
        JS.Function Nothing [] [ JS.Return (JS.Ref realName) ]
    ]


drawCycle :: [Name.Name] -> B.Builder
drawCycle names =
  let
    topLine       = "\\n  ┌─────┐"
    nameLine name = "\\n  │    " <> Name.toBuilder name
    midLine       = "\\n  │     ↓"
    bottomLine    = "\\n  └─────┘"
  in
  mconcat (topLine : List.intersperse midLine (map nameLine names) ++ [ bottomLine ])



-- GENERATE KERNEL


generateKernel :: Mode.Mode -> [K.Chunk] -> B.Builder
generateKernel mode chunks =
  List.foldr (addChunk mode) mempty chunks


addChunk :: Mode.Mode -> K.Chunk -> B.Builder -> B.Builder
addChunk mode chunk builder =
  case chunk of
    K.JS javascript ->
      B.byteString javascript <> builder

    K.ElmVar home name ->
      JsName.toBuilder (JsName.fromGlobal home name) <> builder

    K.JsVar home name ->
      JsName.toBuilder (JsName.fromKernel home name) <> builder

    K.ElmField name ->
      JsName.toBuilder (Expr.generateField mode name) <> builder

    K.JsField int ->
      JsName.toBuilder (JsName.fromInt int) <> builder

    K.JsEnum int ->
      B.intDec int <> builder

    K.Debug ->
      case mode of
        Mode.Dev _ ->
          builder

        Mode.Prod _ _ ->
          "_UNUSED" <> builder

    K.Prod ->
      case mode of
        Mode.Dev _ ->
          "_UNUSED" <> builder

        Mode.Prod _ _ ->
          builder



-- GENERATE ENUM


generateEnum :: Mode.Mode -> Opt.Global -> Index.ZeroBased -> JS.Stmt
generateEnum mode global@(Opt.Global home name) index =
  JS.Var (JsName.fromGlobal home name) $
    case mode of
      Mode.Dev _ ->
        Expr.codeToExpr (Expr.generateCtor mode global index 0 0)

      Mode.Prod _ _ ->
        JS.Int (Index.toMachine index)



-- GENERATE BOX


generateBox :: Mode.Mode -> Opt.Global -> JS.Stmt
generateBox mode global@(Opt.Global home name) =
  JS.Var (JsName.fromGlobal home name) $
    case mode of
      Mode.Dev _ ->
        Expr.codeToExpr (Expr.generateCtor mode global Index.first 1 1)

      Mode.Prod _ _ ->
        JS.Ref (JsName.fromGlobal ModuleName.basics Name.identity)


{-# NOINLINE identity #-}
identity :: Opt.Global
identity =
  Opt.Global ModuleName.basics Name.identity



-- GENERATE PORTS


generatePort :: Mode.Mode -> Opt.Global -> Name.Name -> Opt.Expr -> JS.Stmt
generatePort mode (Opt.Global home name) makePort converter =
  JS.Var (JsName.fromGlobal home name) $
    JS.Call (JS.Ref (JsName.fromKernel Name.platform makePort))
      [ JS.String (Name.toBuilder name)
      , Expr.codeToExpr (Expr.generate mode converter)
      ]



-- GENERATE MANAGER


generateManager :: Mode.Mode -> Graph -> Opt.Global -> Opt.EffectsType -> State -> State
generateManager mode graph (Opt.Global home@(ModuleName.Canonical _ moduleName) _) effectsType state =
  let
    managerLVar =
      JS.LBracket
        (JS.Ref (JsName.fromKernel Name.platform "effectManagers"))
        (JS.String (Name.toBuilder moduleName))

    (deps, args, stmts) =
      generateManagerHelp home effectsType

    createManager =
      JS.ExprStmt $ JS.Assign managerLVar $
        JS.Call (JS.Ref (JsName.fromKernel Name.platform "createManager")) args
  in
  addStmt (List.foldl' (addGlobal mode graph) state deps) $
    JS.Block (createManager : stmts)


generateLeaf :: ModuleName.Canonical -> Name.Name -> JS.Stmt
generateLeaf home@(ModuleName.Canonical _ moduleName) name =
  JS.Var (JsName.fromGlobal home name) $
    JS.Call leaf [ JS.String (Name.toBuilder moduleName) ]



{-# NOINLINE leaf #-}
leaf :: JS.Expr
leaf =
  JS.Ref (JsName.fromKernel Name.platform "leaf")


generateManagerHelp :: ModuleName.Canonical -> Opt.EffectsType -> ([Opt.Global], [JS.Expr], [JS.Stmt])
generateManagerHelp home effectsType =
  let
    dep name = Opt.Global home name
    ref name = JS.Ref (JsName.fromGlobal home name)
  in
  case effectsType of
    Opt.Cmd ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap" ]
      , [ generateLeaf home "command" ]
      )

    Opt.Sub ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "subMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", JS.Int 0, ref "subMap" ]
      , [ generateLeaf home "subscription" ]
      )

    Opt.Fx ->
      ( [ dep "init", dep "onEffects", dep "onSelfMsg", dep "cmdMap", dep "subMap" ]
      , [ ref "init", ref "onEffects", ref "onSelfMsg", ref "cmdMap", ref "subMap" ]
      , [ generateLeaf home "command"
        , generateLeaf home "subscription"
        ]
      )



-- MAIN EXPORTS


toMainExports :: Mode.Mode -> Mains -> B.Builder
toMainExports mode mains =
  let
    export = JsName.fromKernel Name.platform "export"
    exports = generateExports mode (Map.foldrWithKey addToTrie emptyTrie mains)
  in
  JsName.toBuilder export <> "(" <> exports <> ");"


generateExports :: Mode.Mode -> Trie -> B.Builder
generateExports mode (Trie maybeMain subs) =
  let
    starter end =
      case maybeMain of
        Nothing ->
          "{"

        Just (home, main) ->
          "{'init':"
          <> JS.exprToBuilder (Expr.generateMain mode home main)
          <> end
    in
    case Map.toList subs of
      [] ->
        starter "" <> "}"

      (name, subTrie) : otherSubTries ->
        starter "," <>
        "'" <> Utf8.toBuilder name <> "':"
        <> generateExports mode subTrie
        <> List.foldl' (addSubTrie mode) "}" otherSubTries


addSubTrie :: Mode.Mode -> B.Builder -> (Name.Name, Trie) -> B.Builder
addSubTrie mode end (name, trie) =
  ",'" <> Utf8.toBuilder name <> "':" <> generateExports mode trie <> end



-- BUILD TRIES


data Trie =
  Trie
    { _main :: Maybe (ModuleName.Canonical, Opt.Main)
    , _subs :: Map.Map Name.Name Trie
    }


emptyTrie :: Trie
emptyTrie =
  Trie Nothing Map.empty


addToTrie :: ModuleName.Canonical -> Opt.Main -> Trie -> Trie
addToTrie home@(ModuleName.Canonical _ moduleName) main trie =
  merge trie $ segmentsToTrie home (Name.splitDots moduleName) main


segmentsToTrie :: ModuleName.Canonical -> [Name.Name] -> Opt.Main -> Trie
segmentsToTrie home segments main =
  case segments of
    [] ->
      Trie (Just (home, main)) Map.empty

    segment : otherSegments ->
      Trie Nothing (Map.singleton segment (segmentsToTrie home otherSegments main))


merge :: Trie -> Trie -> Trie
merge (Trie main1 subs1) (Trie main2 subs2) =
  Trie
    (checkedMerge main1 main2)
    (Map.unionWith merge subs1 subs2)


checkedMerge :: Maybe a -> Maybe a -> Maybe a
checkedMerge a b =
  case (a, b) of
    (Nothing, main) ->
      main

    (main, Nothing) ->
      main

    (Just _, Just _) ->
      error "cannot have two modules with the same name"
