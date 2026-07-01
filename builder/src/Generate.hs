{-# LANGUAGE BangPatterns #-}
module Generate
  ( debug
  , dev
  , prod
  , repl
  , debugSourceMaps
  , devSourceMaps
  )
  where


import Prelude hiding (cycle, print)
import Control.Concurrent (MVar, forkIO, newEmptyMVar, newMVar, putMVar, readMVar)
import Control.Monad (liftM2)
import qualified Data.ByteString.Builder as B
import Data.Map ((!))
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Name as N
import qualified Data.NonEmptyList as NE
import qualified System.Directory as Dir
import qualified System.FilePath as FP

import qualified AST.Optimized as Opt
import qualified Build
import qualified Elm.Compiler.Type.Extract as Extract
import qualified Elm.Details as Details
import qualified Elm.Interface as I
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Outline as Outline
import qualified Elm.Package as Pkg
import qualified File
import qualified Generate.JavaScript as JS
import qualified Generate.Mode as Mode
import qualified Generate.SourceMap as SourceMap
import qualified Nitpick.Debug as Nitpick
import qualified Reporting.Exit as Exit
import qualified Reporting.Task as Task
import qualified Stuff


-- NOTE: This is used by Make, Repl, and Reactor right now. But it may be
-- desireable to have Repl and Reactor to keep foreign objects in memory
-- to make things a bit faster?



-- GENERATORS


type Task a =
  Task.Task Exit.Generate a


debug :: FilePath -> Details.Details -> Build.Artifacts -> Task B.Builder
debug root details (Build.Artifacts pkg ifaces roots modules) =
  do  loading <- loadObjects root details modules
      types   <- loadTypes root ifaces modules
      objects <- finalizeObjects loading
      let mode = Mode.Dev (Just types)
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      return $ JS.generate mode False Map.empty graph mains


dev :: FilePath -> Details.Details -> Build.Artifacts -> Task B.Builder
dev root details (Build.Artifacts pkg _ roots modules) =
  do  objects <- finalizeObjects =<< loadObjects root details modules
      let mode = Mode.Dev Nothing
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      return $ JS.generate mode False Map.empty graph mains


prod :: FilePath -> Details.Details -> Build.Artifacts -> Task B.Builder
prod root details (Build.Artifacts pkg _ roots modules) =
  do  objects <- finalizeObjects =<< loadObjects root details modules
      checkForDebugUses objects
      let graph = objectsToGlobalGraph objects
      let mode = Mode.Prod (Mode.shortenFieldNames graph)
      let mains = gatherMains pkg objects roots
      return $ JS.generate mode False Map.empty graph mains


repl :: FilePath -> Details.Details -> Bool -> Build.ReplArtifacts -> N.Name -> Task B.Builder
repl root details ansi (Build.ReplArtifacts home modules localizer annotations) name =
  do  objects <- finalizeObjects =<< loadObjects root details modules
      let graph = objectsToGlobalGraph objects
      return $ JS.generateForRepl ansi localizer graph home name (annotations ! name)



-- GENERATORS WITH SOURCE MAPS


-- These mirror 'dev' and 'debug', but weave source-map markers into the
-- generated JavaScript and return (cleaned JavaScript, source map JSON). The
-- 'fileName' is the base name of the output file (used for the map's "file").


devSourceMaps :: String -> FilePath -> Details.Details -> Build.Artifacts -> Task (B.Builder, B.Builder)
devSourceMaps fileName root details (Build.Artifacts pkg _ roots modules) =
  do  objects <- finalizeObjects =<< loadObjects root details modules
      let mode = Mode.Dev Nothing
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      (sources, modIdx) <- Task.io (prepareSources root pkg details modules)
      return $ SourceMap.extract fileName sources (JS.generate mode True modIdx graph mains)


debugSourceMaps :: String -> FilePath -> Details.Details -> Build.Artifacts -> Task (B.Builder, B.Builder)
debugSourceMaps fileName root details (Build.Artifacts pkg ifaces roots modules) =
  do  loading <- loadObjects root details modules
      types   <- loadTypes root ifaces modules
      objects <- finalizeObjects loading
      let mode = Mode.Dev (Just types)
      let graph = objectsToGlobalGraph objects
      let mains = gatherMains pkg objects roots
      (sources, modIdx) <- Task.io (prepareSources root pkg details modules)
      return $ SourceMap.extract fileName sources (JS.generate mode True modIdx graph mains)


-- Resolves every built local module to its .elm file (via the project's source
-- directories), reads its content, and keeps the ordering consistent between
-- the [SourceMap.Source] list (index = position) and the module-index map used
-- by code generation. We resolve from the outline rather than Details._locals
-- because _locals is only populated from the on-disk cache (empty on a fresh
-- build).
prepareSources :: FilePath -> Pkg.Name -> Details.Details -> [Build.Module] -> IO ([SourceMap.Source], Map.Map ModuleName.Canonical Int)
prepareSources root pkg details modules =
  do  let srcDirs = outlineSrcDirs (Details._outline details)
      let names = Maybe.mapMaybe moduleRawName modules
      entries <- Maybe.catMaybes <$> traverse (resolveSource root pkg srcDirs) names
      let sources = map snd entries
      let modIdx = Map.fromList (zip (map fst entries) [0..])
      return (sources, modIdx)


moduleRawName :: Build.Module -> Maybe ModuleName.Raw
moduleRawName modul =
  case modul of
    Build.Fresh name _ _  -> Just name
    Build.Cached name _ _ -> Just name


outlineSrcDirs :: Details.ValidOutline -> [Outline.SrcDir]
outlineSrcDirs outline =
  case outline of
    Details.ValidApp dirs  -> NE.toList dirs
    Details.ValidPkg _ _ _ -> [Outline.RelativeSrcDir "src"]


resolveSource :: FilePath -> Pkg.Name -> [Outline.SrcDir] -> ModuleName.Raw -> IO (Maybe (ModuleName.Canonical, SourceMap.Source))
resolveSource root pkg srcDirs name =
  let
    relPath = FP.joinPath (map N.toChars (N.splitDots name)) FP.<.> "elm"

    search dirs =
      case dirs of
        [] ->
          return Nothing

        dir : rest ->
          do  let absPath = srcDirToAbsolute root dir FP.</> relPath
              exists <- Dir.doesFileExist absPath
              case exists of
                False ->
                  search rest

                True ->
                  do  content <- File.readUtf8 absPath
                      let display = srcDirToGiven dir FP.</> relPath
                      return (Just (ModuleName.Canonical pkg name, SourceMap.Source display content))
  in
  search srcDirs


srcDirToAbsolute :: FilePath -> Outline.SrcDir -> FilePath
srcDirToAbsolute root srcDir =
  case srcDir of
    Outline.AbsoluteSrcDir dir -> dir
    Outline.RelativeSrcDir dir -> root FP.</> dir


srcDirToGiven :: Outline.SrcDir -> FilePath
srcDirToGiven srcDir =
  case srcDir of
    Outline.AbsoluteSrcDir dir -> dir
    Outline.RelativeSrcDir dir -> dir



-- CHECK FOR DEBUG


checkForDebugUses :: Objects -> Task ()
checkForDebugUses (Objects _ locals) =
  case Map.keys (Map.filter Nitpick.hasDebugUses locals) of
    []   -> return ()
    m:ms -> Task.throw (Exit.GenerateCannotOptimizeDebugValues m ms)



-- GATHER MAINS


gatherMains :: Pkg.Name -> Objects -> NE.List Build.Root -> Map.Map ModuleName.Canonical Opt.Main
gatherMains pkg (Objects _ locals) roots =
  Map.fromList $ Maybe.mapMaybe (lookupMain pkg locals) (NE.toList roots)


lookupMain :: Pkg.Name -> Map.Map ModuleName.Raw Opt.LocalGraph -> Build.Root -> Maybe (ModuleName.Canonical, Opt.Main)
lookupMain pkg locals root =
  let
    toPair name (Opt.LocalGraph maybeMain _ _) =
      (,) (ModuleName.Canonical pkg name) <$> maybeMain
  in
  case root of
    Build.Inside  name     -> toPair name =<< Map.lookup name locals
    Build.Outside name _ g -> toPair name g



-- LOADING OBJECTS


data LoadingObjects =
  LoadingObjects
    { _foreign_mvar :: MVar (Maybe Opt.GlobalGraph)
    , _local_mvars :: Map.Map ModuleName.Raw (MVar (Maybe Opt.LocalGraph))
    }


loadObjects :: FilePath -> Details.Details -> [Build.Module] -> Task LoadingObjects
loadObjects root details modules =
  Task.io $
  do  mvar <- Details.loadObjects root details
      mvars <- traverse (loadObject root) modules
      return $ LoadingObjects mvar (Map.fromList mvars)


loadObject :: FilePath -> Build.Module -> IO (ModuleName.Raw, MVar (Maybe Opt.LocalGraph))
loadObject root modul =
  case modul of
    Build.Fresh name _ graph ->
      do  mvar <- newMVar (Just graph)
          return (name, mvar)

    Build.Cached name _ _ ->
      do  mvar <- newEmptyMVar
          _ <- forkIO $ putMVar mvar =<< File.readBinary (Stuff.elmo root name)
          return (name, mvar)



-- FINALIZE OBJECTS


data Objects =
  Objects
    { _foreign :: Opt.GlobalGraph
    , _locals :: Map.Map ModuleName.Raw Opt.LocalGraph
    }


finalizeObjects :: LoadingObjects -> Task Objects
finalizeObjects (LoadingObjects mvar mvars) =
  Task.eio id $
  do  result  <- readMVar mvar
      results <- traverse readMVar mvars
      case liftM2 Objects result (sequence results) of
        Just loaded -> return (Right loaded)
        Nothing     -> return (Left Exit.GenerateCannotLoadArtifacts)


objectsToGlobalGraph :: Objects -> Opt.GlobalGraph
objectsToGlobalGraph (Objects globals locals) =
  foldr Opt.addLocalGraph globals locals



-- LOAD TYPES


loadTypes :: FilePath -> Map.Map ModuleName.Canonical I.DependencyInterface -> [Build.Module] -> Task Extract.Types
loadTypes root ifaces modules =
  Task.eio id $
  do  mvars <- traverse (loadTypesHelp root) modules
      let !foreigns = Extract.mergeMany (Map.elems (Map.mapWithKey Extract.fromDependencyInterface ifaces))
      results <- traverse readMVar mvars
      case sequence results of
        Just ts -> return (Right (Extract.merge foreigns (Extract.mergeMany ts)))
        Nothing -> return (Left Exit.GenerateCannotLoadArtifacts)


loadTypesHelp :: FilePath -> Build.Module -> IO (MVar (Maybe Extract.Types))
loadTypesHelp root modul =
  case modul of
    Build.Fresh name iface _ ->
      newMVar (Just (Extract.fromInterface name iface))

    Build.Cached name _ ciMVar ->
      do  cachedInterface <- readMVar ciMVar
          case cachedInterface of
            Build.Unneeded ->
              do  mvar <- newEmptyMVar
                  _ <- forkIO $
                    do  maybeIface <- File.readBinary (Stuff.elmi root name)
                        putMVar mvar (Extract.fromInterface name <$> maybeIface)
                  return mvar

            Build.Loaded iface ->
              newMVar (Just (Extract.fromInterface name iface))

            Build.Corrupted ->
              newMVar Nothing
