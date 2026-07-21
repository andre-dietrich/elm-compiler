{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Nitpick.WorkerRegistry
  ( collect
  )
  where


import qualified Data.Name as Name
import qualified Data.Set as Set

import qualified AST.Optimized as Opt



-- COLLECT
--
-- Whole-program scan (mirrors Nitpick.Debug.hasDebugUses's traversal shape)
-- over the final, merged Opt.GlobalGraph for every top-level function ever
-- passed as the `fn` argument of a Worker.run call site (see
-- Optimize.Expression's buildWorkerRun, which emits the
-- `_Worker_run(tag, fn)` kernel-call shape this looks for). No codecs to
-- collect anymore (Worker.run hands the raw compiled value straight to
-- postMessage, see Nitpick.Worker's module comment) -- Generate.JavaScript
-- just needs to know which Globals require a `_Worker_register(tag, fn)`
-- statement. The tag itself isn't collected here -- it's a pure function of
-- the Opt.Global alone (Generate.JavaScript.Name.workerTag), so the caller
-- recomputes it directly from each Global this returns.


collect :: Opt.GlobalGraph -> Set.Set Opt.Global
collect (Opt.GlobalGraph nodes _) =
  foldMap nodeTargets nodes


nodeTargets :: Opt.Node -> Set.Set Opt.Global
nodeTargets node =
  case node of
    Opt.Define expr _           -> exprTargets expr
    Opt.DefineTailFunc _ expr _ -> exprTargets expr
    Opt.Ctor _ _ _              -> Set.empty
    Opt.Enum _                  -> Set.empty
    Opt.Box                     -> Set.empty
    Opt.Link _                  -> Set.empty
    Opt.Cycle _ vs fs _         -> foldMap (exprTargets . snd) vs <> foldMap defTargets fs
    Opt.Manager _               -> Set.empty
    Opt.Kernel _ _              -> Set.empty
    Opt.PortIncoming expr _     -> exprTargets expr
    Opt.PortOutgoing expr _     -> exprTargets expr


defTargets :: Opt.Def -> Set.Set Opt.Global
defTargets def =
  case def of
    Opt.Def _ expr                 -> exprTargets expr
    Opt.TailDef _ _ expr           -> exprTargets expr
    Opt.TailDefCons _ _ _ _ _ expr -> exprTargets expr


exprTargets :: Opt.Expr -> Set.Set Opt.Global
exprTargets expression =
  case expression of
    Opt.Call (Opt.VarKernel home name) [tagExpr, Opt.VarGlobal g]
      | home == Name.worker, name == "run" ->
          Set.insert g (exprTargets tagExpr)

    Opt.Bool _           -> Set.empty
    Opt.Chr _            -> Set.empty
    Opt.Str _            -> Set.empty
    Opt.Int _            -> Set.empty
    Opt.Float _          -> Set.empty
    Opt.VarLocal _       -> Set.empty
    Opt.VarGlobal _      -> Set.empty
    Opt.VarEnum _ _      -> Set.empty
    Opt.VarBox _         -> Set.empty
    Opt.VarCycle _ _     -> Set.empty
    Opt.VarDebug _ _ _ _ -> Set.empty
    Opt.VarKernel _ _    -> Set.empty
    Opt.List exprs       -> foldMap exprTargets exprs
    Opt.Function _ expr  -> exprTargets expr
    Opt.Call e es        -> exprTargets e <> foldMap exprTargets es
    Opt.TailCall _ args  -> foldMap (exprTargets . snd) args
    Opt.TailCallCons _consInfo _holeIndex _fname otherFields args ->
      foldMap (exprTargets . snd) otherFields <> foldMap (exprTargets . snd) args
    Opt.TailCallConsBase _holeIndex _fname expr -> exprTargets expr
    Opt.If conds finally -> exprTargets finally <> foldMap (\(c,e) -> exprTargets c <> exprTargets e) conds
    Opt.Let def body     -> defTargets def <> exprTargets body
    Opt.Destruct _ expr  -> exprTargets expr
    Opt.Case _ _ decider jumps -> deciderTargets decider <> foldMap (exprTargets . snd) jumps
    Opt.Accessor _       -> Set.empty
    Opt.Access r _       -> exprTargets r
    Opt.Update r fs      -> exprTargets r <> foldMap exprTargets fs
    Opt.Record fs        -> foldMap exprTargets fs
    Opt.Unit             -> Set.empty
    Opt.Tuple a b c      -> exprTargets a <> exprTargets b <> maybe Set.empty exprTargets c
    Opt.Shader _ _ _     -> Set.empty
    Opt.PrimOp _ l r     -> exprTargets l <> exprTargets r


deciderTargets :: Opt.Decider Opt.Choice -> Set.Set Opt.Global
deciderTargets decider =
  case decider of
    Opt.Leaf (Opt.Inline expr)  -> exprTargets expr
    Opt.Leaf (Opt.Jump _)       -> Set.empty
    Opt.Chain _ success failure -> deciderTargets success <> deciderTargets failure
    Opt.FanOut _ tests fallback -> deciderTargets fallback <> foldMap (deciderTargets . snd) tests
