module Generate.Mode
  ( Mode(..)
  , isDebug
  , ShortFieldNames
  , shortenFieldNames
  , Arities
  , computeArities
  , lookupArity
  , lookupUnwrapped
  , lookupRawLocal
  , setRawLocal
  )
  where


import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Name as Name

import qualified AST.Optimized as Opt
import qualified Elm.Compiler.Type.Extract as Extract
import qualified Elm.ModuleName as ModuleName
import qualified Generate.JavaScript.Name as JsName



-- MODE


data Mode
  = Dev (Maybe Extract.Types)
  | Prod ShortFieldNames Arities


isDebug :: Mode -> Bool
isDebug mode =
  case mode of
    Dev mi -> Maybe.isJust mi
    Prod _ _ -> False



-- SHORTEN FIELD NAMES


type ShortFieldNames =
  Map.Map Name.Name JsName.Name


shortenFieldNames :: Opt.GlobalGraph -> ShortFieldNames
shortenFieldNames (Opt.GlobalGraph _ frequencies) =
  Map.foldr addToShortNames Map.empty $
    Map.foldrWithKey addToBuckets Map.empty frequencies


addToBuckets :: Name.Name -> Int -> Map.Map Int [Name.Name] -> Map.Map Int [Name.Name]
addToBuckets field frequency buckets =
  Map.insertWith (++) frequency [field] buckets


addToShortNames :: [Name.Name] -> ShortFieldNames -> ShortFieldNames
addToShortNames fields shortNames =
  List.foldl' addField shortNames fields


addField :: ShortFieldNames -> Name.Name -> ShortFieldNames
addField shortNames field =
  let rename = JsName.fromInt (Map.size shortNames) in
  Map.insert field rename shortNames



-- ARITIES
--
-- Every 2..9-ary call goes through `A2`..`A9`, which exist so that a
-- function can be partially applied when it is used as a value:
--
--     A2(fun, a, b) = fun.a === 2 ? fun.f(a, b) : fun(a)(b)
--
-- When a call site refers directly to a known top-level definition
-- (function, tail-recursive function, or constructor) and supplies
-- exactly that many arguments, the `fun.a === N` branch is always taken.
-- We can decide that at compile time instead, call `fun.f` directly, and
-- skip the check. Just as important: every such call site becomes
-- monomorphic for the JS engine (it always reads `.f` off the very same
-- global), instead of funneling every saturated call of that arity in
-- the whole program through the single shared `A2`..`A9` call site, which
-- forces the engine's inline cache there into megamorphic mode.


data Arities =
  Arities
    { _arities :: Map.Map Opt.Global Int
    , _unwrapped :: Map.Map Opt.Global (Int, Int)
    , _rawLocal :: Maybe (Name.Name, Int)
    }


computeArities :: Opt.GlobalGraph -> Arities
computeArities (Opt.GlobalGraph nodes _) =
  let arities = Map.mapMaybeWithKey (nodeArity nodes) nodes in
  Arities arities (computeUnwrapped nodes arities) Nothing


lookupArity :: Mode -> Opt.Global -> Maybe Int
lookupArity mode global =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities arities _ _) -> Map.lookup global arities


-- Which globals have an `$unwrapped` sibling definition, which of their
-- parameters is the raw callback, and with how many arguments that
-- callback is always called. See UNWRAPPED HIGHER-ORDER FUNCTIONS below.
lookupUnwrapped :: Mode -> Opt.Global -> Maybe (Int, Int)
lookupUnwrapped mode global =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities _ unwrapped _) -> Map.lookup global unwrapped


-- While generating the body of an `$unwrapped` variant, the callback
-- parameter holds a raw JS function (of the given arity) instead of an
-- F2..F9-wrapped one. Call sites of that local must not go through A2..A9.
lookupRawLocal :: Mode -> Maybe (Name.Name, Int)
lookupRawLocal mode =
  case mode of
    Dev _ -> Nothing
    Prod _ (Arities _ _ raw) -> raw


setRawLocal :: Name.Name -> Int -> Mode -> Mode
setRawLocal name arity mode =
  case mode of
    Dev _ -> mode
    Prod fields (Arities arities unwrapped _) ->
      Prod fields (Arities arities unwrapped (Just (name, arity)))


nodeArity :: Map.Map Opt.Global Opt.Node -> Opt.Global -> Opt.Node -> Maybe Int
nodeArity nodes (Opt.Global _ name) node =
  restrictRange =<<
    case node of
      Opt.Define expr _           -> functionArity expr
      Opt.DefineTailFunc args _ _ -> Just (length args)
      Opt.Ctor _ arity _          -> Just arity
      Opt.Link linked             -> cycleArity nodes linked name
      _                           -> Nothing


restrictRange :: Int -> Maybe Int
restrictRange n =
  if n >= 2 && n <= 9 then Just n else Nothing


functionArity :: Opt.Expr -> Maybe Int
functionArity expr =
  case expr of
    Opt.Function args _ -> Just (length args)
    _                    -> Nothing


-- A member of a recursive let-block is stored as `Global -> Link cycleName`,
-- with the real definitions bundled up in one `Cycle` node under `cycleName`.
-- Find the specific definition that matches the original name.
cycleArity :: Map.Map Opt.Global Opt.Node -> Opt.Global -> Name.Name -> Maybe Int
cycleArity nodes linked name =
  case Map.lookup linked nodes of
    Just (Opt.Cycle _ _ functions _) -> findDefArity name functions
    _                                 -> Nothing


findDefArity :: Name.Name -> [Opt.Def] -> Maybe Int
findDefArity name defs =
  case defs of
    [] ->
      Nothing

    Opt.Def defName expr : rest ->
      if defName == name then functionArity expr else findDefArity name rest

    Opt.TailDef defName args _ : rest ->
      if defName == name then Just (length args) else findDefArity name rest



-- UNWRAPPED HIGHER-ORDER FUNCTIONS
--
-- Elm-defined higher-order functions like List.foldl receive their callback
-- as an F2..F9-wrapped value and invoke it with `A2(func, x, acc)` on every
-- element: a runtime arity check plus a wrapper frame that JS engines do
-- not inline through. When every use of a callback parameter inside a
-- definition is a saturated call with one constant argument count -- or the
-- parameter is merely passed along, in tail position to itself or as an
-- argument to another definition that qualifies the same way -- a second
-- `$unwrapped` version of the definition can be emitted whose callback
-- parameter is a plain JS function, called directly. Call sites whose
-- callback argument has statically known arity are redirected to it.
--
-- The result maps each qualifying global to (parameter index, callback
-- arity). At most one parameter per global qualifies (the leftmost).


data Candidate =
  Candidate
    { _direct :: Maybe Int             -- arity of direct calls of the param
    , _forwards :: [(Opt.Global, Int)] -- passed along to these params
    }


computeUnwrapped :: Map.Map Opt.Global Opt.Node -> Map.Map Opt.Global Int -> Map.Map Opt.Global (Int, Int)
computeUnwrapped nodes arities =
  finalize (Map.foldrWithKey (addCandidates arities) Map.empty nodes)


addCandidates
  :: Map.Map Opt.Global Int
  -> Opt.Global
  -> Opt.Node
  -> Map.Map (Opt.Global, Int) Candidate
  -> Map.Map (Opt.Global, Int) Candidate
addCandidates arities global node candidates =
  case node of
    Opt.Define (Opt.Function params body) _ ->
      addParams arities global params body candidates

    Opt.DefineTailFunc params body _ ->
      addParams arities global params body candidates

    -- self-recursive definitions (foldl!) land in a Cycle node, with the
    -- real definitions bundled as its function members
    Opt.Cycle _ _ functions _ ->
      let (Opt.Global home _) = global in
      List.foldl' (addCycleFunc arities home) candidates functions

    _ ->
      candidates


addCycleFunc
  :: Map.Map Opt.Global Int
  -> ModuleName.Canonical
  -> Map.Map (Opt.Global, Int) Candidate
  -> Opt.Def
  -> Map.Map (Opt.Global, Int) Candidate
addCycleFunc arities home candidates def =
  case def of
    Opt.Def name (Opt.Function params body) ->
      addParams arities (Opt.Global home name) params body candidates

    Opt.Def _ _ ->
      candidates

    Opt.TailDef name params body ->
      addParams arities (Opt.Global home name) params body candidates


addParams
  :: Map.Map Opt.Global Int
  -> Opt.Global
  -> [Name.Name]
  -> Opt.Expr
  -> Map.Map (Opt.Global, Int) Candidate
  -> Map.Map (Opt.Global, Int) Candidate
addParams arities global@(Opt.Global _ self) params body candidates =
  -- the global itself must have a known arity so that rewritten call
  -- sites can be checked for saturation
  if Map.lookup global arities /= Just (length params) then
    candidates
  else
    List.foldl' addParam candidates (zip [0..] params)
  where
    addParam cands (i, param) =
      case scanParam arities self param body of
        Just candidate@(Candidate direct forwards)
          | Maybe.isJust direct || not (null forwards) ->
              Map.insert (global, i) candidate cands

        _ ->
          cands


-- Check every occurrence of the parameter in the body. `Nothing` means the
-- parameter escapes (used as a value, shadowed, rebound, destructured, or
-- called with inconsistent arity) and cannot be a raw callback.
scanParam :: Map.Map Opt.Global Int -> Name.Name -> Name.Name -> Opt.Expr -> Maybe Candidate
scanParam arities self param body =
  scan body
  where
    none = Just (Candidate Nothing [])

    merge a b =
      case (a, b) of
        (Just (Candidate d1 f1), Just (Candidate d2 f2)) ->
          case (d1, d2) of
            (Just n1, Just n2) | n1 /= n2 -> Nothing
            _ -> Just (Candidate (maybe d2 Just d1) (f1 ++ f2))

        _ ->
          Nothing

    merges = List.foldl' merge none

    isBare expr =
      case expr of
        Opt.VarLocal x -> x == param
        _ -> False

    scan expr =
      case expr of
        Opt.VarLocal x ->
          if x == param then Nothing else none

        Opt.Call (Opt.VarLocal x) args | x == param ->
          let n = length args in
          if n >= 2 && n <= 9
            then merge (Just (Candidate (Just n) [])) (merges (map scan args))
            else Nothing

        Opt.Call (Opt.VarGlobal h) args ->
          let bare = [ (h, j) | (j, arg) <- zip [0..] args, isBare arg ] in
          if null bare then
            merges (map scan args)
          else if Map.lookup h arities == Just (length args) then
            merge
              (Just (Candidate Nothing bare))
              (merges (map scan (filter (not . isBare) args)))
          else
            Nothing

        Opt.Call f args ->
          merges (scan f : map scan args)

        Opt.TailCall fname pairs ->
          merges (map (scanPair fname) pairs)

        Opt.Function args funcBody ->
          if elem param args then Nothing else scan funcBody

        Opt.Let def letBody ->
          if defShadows def then Nothing else merge (scanDef def) (scan letBody)

        Opt.Destruct (Opt.Destructor name path) destructBody ->
          if name == param || pathRoot path == param
            then Nothing
            else scan destructBody

        Opt.Case _ root decider jumps ->
          if root == param
            then Nothing
            else merges (scanDecider decider : map (scan . snd) jumps)

        Opt.If branches final ->
          merges (scan final : concatMap (\(c, b) -> [scan c, scan b]) branches)

        Opt.Access record _  -> scan record
        Opt.Update record fields -> merges (scan record : map scan (Map.elems fields))
        Opt.Record fields    -> merges (map scan (Map.elems fields))
        Opt.Tuple a b maybeC -> merges [scan a, scan b, maybe none scan maybeC]
        Opt.List entries     -> merges (map scan entries)
        Opt.PrimOp _ l r     -> merge (scan l) (scan r)

        Opt.Bool _       -> none
        Opt.Chr _        -> none
        Opt.Str _        -> none
        Opt.Int _        -> none
        Opt.Float _      -> none
        Opt.VarGlobal _  -> none
        Opt.VarEnum _ _  -> none
        Opt.VarBox _     -> none
        Opt.VarCycle _ _ -> none
        Opt.VarDebug _ _ _ _ -> none
        Opt.VarKernel _ _ -> none
        Opt.Accessor _   -> none
        Opt.Unit         -> none
        Opt.Shader _ _ _ -> none

    scanPair fname (name, expr) =
      if isBare expr then
        -- passing the callback into the next iteration of the same loop
        if fname == self && name == param then none else Nothing
      else if name == param then
        -- rebinding the callback parameter to something else
        Nothing
      else
        scan expr

    defShadows def =
      case def of
        Opt.Def name _ -> name == param
        Opt.TailDef name args _ -> name == param || elem param args

    scanDef def =
      case def of
        Opt.Def _ expr -> scan expr
        Opt.TailDef _ _ expr -> scan expr

    scanDecider decider =
      case decider of
        Opt.Leaf (Opt.Inline expr) -> scan expr
        Opt.Leaf (Opt.Jump _) -> none
        Opt.Chain _ success failure -> merge (scanDecider success) (scanDecider failure)
        Opt.FanOut _ tests fallback ->
          merges (scanDecider fallback : map (scanDecider . snd) tests)

    pathRoot path =
      case path of
        Opt.Index _ subPath -> pathRoot subPath
        Opt.Field _ subPath -> pathRoot subPath
        Opt.Unbox subPath -> pathRoot subPath
        Opt.Root name -> name


-- Resolve the forward graph: a candidate survives only if all the params
-- it forwards to are themselves surviving candidates with the same
-- callback arity. Then keep at most one param per global (the leftmost)
-- and re-resolve, since dropping the others may invalidate forwards.
finalize :: Map.Map (Opt.Global, Int) Candidate -> Map.Map Opt.Global (Int, Int)
finalize candidates =
  let
    selected = pickLeftmost (solve candidates)
    solved = solve (Map.restrictKeys candidates (Map.keysSet selected))
  in
  Map.fromList [ (global, (i, n)) | ((global, i), n) <- Map.toList solved ]


solve :: Map.Map (Opt.Global, Int) Candidate -> Map.Map (Opt.Global, Int) Int
solve candidates =
  keep (propagate (Map.mapMaybe _direct candidates))
  where
    -- spread known arities through pass-through-only candidates (e.g.
    -- foldr knows its callback arity only via foldrHelper)
    propagate known =
      let known' = Map.union known (Map.mapMaybe (adopt known) candidates) in
      if Map.size known' == Map.size known then known else propagate known'

    adopt known (Candidate _ forwards) =
      case Maybe.mapMaybe (\f -> Map.lookup f known) forwards of
        n : _ -> Just n
        [] -> Nothing

    -- drop candidates whose forwards point at dropped or conflicting
    -- candidates, repeating since removals can cascade
    keep known =
      let known' = Map.filterWithKey (ok known) known in
      if Map.size known' == Map.size known then known' else keep known'

    ok known key n =
      case Map.lookup key candidates of
        Nothing ->
          False

        Just (Candidate direct forwards) ->
          maybe True (== n) direct
            && all (\f -> Map.lookup f known == Just n) forwards


pickLeftmost :: Map.Map (Opt.Global, Int) Int -> Map.Map (Opt.Global, Int) Int
pickLeftmost solved =
  let
    leftmost = Map.fromListWith min [ (global, i) | (global, i) <- Map.keys solved ]
  in
  Map.filterWithKey (\(global, i) _ -> Map.lookup global leftmost == Just i) solved
