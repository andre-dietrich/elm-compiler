{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Nitpick.WorkerRegistry
  ( collect
  )
  where


import qualified Data.Map as Map
import qualified Data.Name as Name

import qualified AST.Optimized as Opt



-- COLLECT
--
-- Whole-program scan (mirrors Nitpick.Debug.hasDebugUses's traversal shape)
-- over the final, merged Opt.GlobalGraph for every top-level function ever
-- passed as the `fn` argument of a Worker.run call site (see
-- Optimize.Expression's buildWorkerRun, which emits the
-- `_Worker_run(tag, encodeArg, decodeResult, decodeArg, encodeResult, fn)`
-- kernel-call shape this looks for). Returns the worker-side codec pair
-- (decodeArg, encodeResult) alongside each Global -- the mirror image of
-- the main-thread pair (encodeArg, decodeResult) `_Worker_run` itself
-- reads -- so Generate.JavaScript's registration statement can give the
-- worker-side dispatcher a decoder for the incoming payload and an encoder
-- for `fn`'s result. The tag itself isn't collected here -- it's a pure
-- function of the Opt.Global alone (Generate.JavaScript.Name.workerTag), so
-- the caller recomputes it directly from each Global this returns.


collect :: Opt.GlobalGraph -> Map.Map Opt.Global (Opt.Expr, Opt.Expr)
collect (Opt.GlobalGraph nodes _) =
  Map.foldr (\node acc -> Map.union (nodeTargets node) acc) Map.empty nodes


nodeTargets :: Opt.Node -> Map.Map Opt.Global (Opt.Expr, Opt.Expr)
nodeTargets node =
  case node of
    Opt.Define expr _           -> exprTargets expr
    Opt.DefineTailFunc _ expr _ -> exprTargets expr
    Opt.Ctor _ _ _              -> Map.empty
    Opt.Enum _                  -> Map.empty
    Opt.Box                     -> Map.empty
    Opt.Link _                  -> Map.empty
    Opt.Cycle _ vs fs _         -> Map.unions (map (exprTargets . snd) vs ++ map defTargets fs)
    Opt.Manager _               -> Map.empty
    Opt.Kernel _ _              -> Map.empty
    Opt.PortIncoming expr _     -> exprTargets expr
    Opt.PortOutgoing expr _     -> exprTargets expr


defTargets :: Opt.Def -> Map.Map Opt.Global (Opt.Expr, Opt.Expr)
defTargets def =
  case def of
    Opt.Def _ expr                 -> exprTargets expr
    Opt.TailDef _ _ expr           -> exprTargets expr
    Opt.TailDefCons _ _ _ _ _ expr -> exprTargets expr


exprTargets :: Opt.Expr -> Map.Map Opt.Global (Opt.Expr, Opt.Expr)
exprTargets expression =
  case expression of
    Opt.Call (Opt.VarKernel home name) [tagExpr, encArgExpr, decResultExpr, decArgExpr, encResultExpr, Opt.VarGlobal g]
      | home == Name.worker, name == "run" ->
          Map.unions
            [ Map.singleton g (decArgExpr, encResultExpr)
            , exprTargets tagExpr, exprTargets encArgExpr, exprTargets decResultExpr
            , exprTargets decArgExpr, exprTargets encResultExpr
            ]

    Opt.Bool _           -> Map.empty
    Opt.Chr _            -> Map.empty
    Opt.Str _            -> Map.empty
    Opt.Int _            -> Map.empty
    Opt.Float _          -> Map.empty
    Opt.VarLocal _       -> Map.empty
    Opt.VarGlobal _      -> Map.empty
    Opt.VarEnum _ _      -> Map.empty
    Opt.VarBox _         -> Map.empty
    Opt.VarCycle _ _     -> Map.empty
    Opt.VarDebug _ _ _ _ -> Map.empty
    Opt.VarKernel _ _    -> Map.empty
    Opt.List exprs       -> Map.unions (map exprTargets exprs)
    Opt.Function _ expr  -> exprTargets expr
    Opt.Call e es        -> Map.unions (exprTargets e : map exprTargets es)
    Opt.TailCall _ args  -> Map.unions (map (exprTargets . snd) args)
    Opt.TailCallCons _consInfo _holeIndex _fname otherFields args ->
      Map.unions (map (exprTargets . snd) otherFields ++ map (exprTargets . snd) args)
    Opt.TailCallConsBase _holeIndex _fname expr -> exprTargets expr
    Opt.If conds finally -> Map.unions (exprTargets finally : concatMap (\(c,e) -> [exprTargets c, exprTargets e]) conds)
    Opt.Let def body     -> Map.union (defTargets def) (exprTargets body)
    Opt.Destruct _ expr  -> exprTargets expr
    Opt.Case _ _ decider jumps -> Map.union (deciderTargets decider) (Map.unions (map (exprTargets . snd) jumps))
    Opt.Accessor _       -> Map.empty
    Opt.Access r _       -> exprTargets r
    Opt.Update r fs      -> Map.union (exprTargets r) (Map.unions (map exprTargets (Map.elems fs)))
    Opt.Record fs        -> Map.unions (map exprTargets (Map.elems fs))
    Opt.Unit             -> Map.empty
    Opt.Tuple a b c      -> Map.unions [exprTargets a, exprTargets b, maybe Map.empty exprTargets c]
    Opt.Shader _ _ _     -> Map.empty
    Opt.PrimOp _ l r     -> Map.union (exprTargets l) (exprTargets r)


deciderTargets :: Opt.Decider Opt.Choice -> Map.Map Opt.Global (Opt.Expr, Opt.Expr)
deciderTargets decider =
  case decider of
    Opt.Leaf (Opt.Inline expr)  -> exprTargets expr
    Opt.Leaf (Opt.Jump _)       -> Map.empty
    Opt.Chain _ success failure -> Map.union (deciderTargets success) (deciderTargets failure)
    Opt.FanOut _ tests fallback -> Map.union (deciderTargets fallback) (Map.unions (map (deciderTargets . snd) tests))
