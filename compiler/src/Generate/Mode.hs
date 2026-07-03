module Generate.Mode
  ( Mode(..)
  , isDebug
  , ShortFieldNames
  , shortenFieldNames
  , Arities
  , computeArities
  , lookupArity
  )
  where


import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Name as Name

import qualified AST.Optimized as Opt
import qualified Elm.Compiler.Type.Extract as Extract
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


type Arities =
  Map.Map Opt.Global Int


computeArities :: Opt.GlobalGraph -> Arities
computeArities (Opt.GlobalGraph nodes _) =
  Map.mapMaybeWithKey (nodeArity nodes) nodes


lookupArity :: Mode -> Opt.Global -> Maybe Int
lookupArity mode global =
  case mode of
    Dev _ -> Nothing
    Prod _ arities -> Map.lookup global arities


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
