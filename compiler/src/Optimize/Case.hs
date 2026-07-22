module Optimize.Case
  ( optimize
  )
  where


import Control.Arrow (second)
import Data.List (foldl')
import qualified Data.Map as Map
import Data.Map ((!))
import qualified Data.Maybe as Maybe
import qualified Data.Name as Name

import qualified AST.Canonical as Can
import qualified AST.Optimized as Opt
import qualified Optimize.DecisionTree as DT
import qualified Reporting.Annotation as A



-- OPTIMIZE A CASE EXPRESSION


optimize :: Name.Name -> Name.Name -> [(Can.Pattern, Opt.Expr)] -> Opt.Expr
optimize temp root optBranches =
  let
    (patterns, indexedBranches) =
      assignTargets optBranches

    decider = treeToDecider (DT.compile patterns)
    targetCounts = countTargets decider

    (choices, maybeJumps) =
        unzip (map (createChoices targetCounts) indexedBranches)
  in
  Opt.Case temp root
    (insertChoices (Map.fromList choices) decider)
    (Maybe.catMaybes maybeJumps)



-- ASSIGN TARGETS
--
-- Every case-arm needs a target index for DT.compile. Normally that would
-- just be its position (0, 1, 2, ...). But when two or more arms have a
-- pattern that binds no variable and an (already-optimized) body that is
-- structurally identical, they are given the SAME target index instead of
-- fresh ones -- letting the existing countTargets/createChoices/Opt.Jump
-- mechanism (below, unmodified) share the compiled code between them,
-- exactly the way it already shares code for any target reached by 2+
-- leaves today. See the design spec
-- (docs/superpowers/specs/2026-07-22-decision-tree-dag-sharing-design.md)
-- for why this is only safe when neither arm's pattern binds a variable.


assignTargets :: [(Can.Pattern, Opt.Expr)] -> ([(Can.Pattern, Int)], [(Int, Opt.Expr)])
assignTargets optBranches =
  let
    (patternsRev, branchesRev, _, _) =
      foldl' assignTarget ([], [], [], 0) optBranches
  in
  (reverse patternsRev, reverse branchesRev)


type Seen = [(Opt.Expr, Int)]


assignTarget
    :: ([(Can.Pattern, Int)], [(Int, Opt.Expr)], Seen, Int)
    -> (Can.Pattern, Opt.Expr)
    -> ([(Can.Pattern, Int)], [(Int, Opt.Expr)], Seen, Int)
assignTarget (patternsAcc, branchesAcc, seen, nextFresh) (pattern, branch) =
  case findSharedTarget seen pattern branch of
    Just target ->
      ( (pattern, target) : patternsAcc
      , branchesAcc
      , seen
      , nextFresh
      )

    Nothing ->
      let
        newSeen =
          if bindsNoVariables pattern then
            (branch, nextFresh) : seen
          else
            seen
      in
      ( (pattern, nextFresh) : patternsAcc
      , (nextFresh, branch) : branchesAcc
      , newSeen
      , nextFresh + 1
      )


findSharedTarget :: Seen -> Can.Pattern -> Opt.Expr -> Maybe Int
findSharedTarget seen pattern branch =
  if bindsNoVariables pattern then
    Maybe.listToMaybe
      [ target | (seenBranch, target) <- seen, sameExpr branch seenBranch ]
  else
    Nothing



-- BINDS NO VARIABLES
--
-- Only a pattern that binds nothing at all is safe to merge: a variable
-- bound by one arm's pattern might be extracted from a different sub-
-- position than the "same" name bound by another arm's pattern, so sharing
-- a body that reads such a variable could read the wrong value. A body
-- reached through a variable-free pattern can't depend on which arm
-- reached it, so merging two such equal bodies is always sound.


bindsNoVariables :: Can.Pattern -> Bool
bindsNoVariables (A.At _ pattern) =
  case pattern of
    Can.PAnything ->
      True

    Can.PVar _ ->
      False

    Can.PRecord _ ->
      False

    Can.PAlias _ _ ->
      False

    Can.PUnit ->
      True

    Can.PTuple a b maybeC ->
      bindsNoVariables a && bindsNoVariables b && maybe True bindsNoVariables maybeC

    Can.PList ps ->
      all bindsNoVariables ps

    Can.PCons hd tl ->
      bindsNoVariables hd && bindsNoVariables tl

    Can.PBool _ _ ->
      True

    Can.PChr _ ->
      True

    Can.PStr _ ->
      True

    Can.PInt _ ->
      True

    Can.PCtor _ _ _ _ _ args ->
      all (bindsNoVariables . argPattern) args


argPattern :: Can.PatternCtorArg -> Can.Pattern
argPattern (Can.PatternCtorArg _ _ pattern) =
  pattern



-- SAME EXPR
--
-- A hand-written, deliberately conservative structural equality over
-- already-optimized Opt.Expr, used only to decide whether two variable-
-- free branch bodies are worth merging. It only knows about constructors
-- that can appear in such a body without introducing a new binding
-- (literals, variable/global references, calls, tuples, lists, if, field
-- access); everything else (Let, Destruct, Case, Function, the TailCall
-- variants, Update, Record, Shader, PrimOp, ...) always compares unequal,
-- even to itself. Returning False only ever misses a sharing opportunity;
-- it can never cause an incorrect merge.


sameExpr :: Opt.Expr -> Opt.Expr -> Bool
sameExpr expr1 expr2 =
  case (expr1, expr2) of
    (Opt.Bool a, Opt.Bool b) ->
      a == b

    (Opt.Chr a, Opt.Chr b) ->
      a == b

    (Opt.Str a, Opt.Str b) ->
      a == b

    (Opt.Int a, Opt.Int b) ->
      a == b

    (Opt.Float a, Opt.Float b) ->
      a == b

    (Opt.Unit, Opt.Unit) ->
      True

    (Opt.VarLocal a, Opt.VarLocal b) ->
      a == b

    (Opt.VarGlobal g1, Opt.VarGlobal g2) ->
      sameGlobal g1 g2

    (Opt.VarEnum g1 i1, Opt.VarEnum g2 i2) ->
      sameGlobal g1 g2 && i1 == i2

    (Opt.VarBox g1, Opt.VarBox g2) ->
      sameGlobal g1 g2

    (Opt.VarKernel h1 a, Opt.VarKernel h2 b) ->
      h1 == h2 && a == b

    (Opt.List xs1, Opt.List xs2) ->
      sameExprList xs1 xs2

    (Opt.Call f1 args1, Opt.Call f2 args2) ->
      sameExpr f1 f2 && sameExprList args1 args2

    (Opt.If branches1 final1, Opt.If branches2 final2) ->
      sameBranchList branches1 branches2 && sameExpr final1 final2

    (Opt.Accessor a, Opt.Accessor b) ->
      a == b

    (Opt.Access e1 a, Opt.Access e2 b) ->
      sameExpr e1 e2 && a == b

    (Opt.Tuple a1 b1 c1, Opt.Tuple a2 b2 c2) ->
      sameExpr a1 a2 && sameExpr b1 b2 && sameMaybeExpr c1 c2

    _ ->
      False


sameGlobal :: Opt.Global -> Opt.Global -> Bool
sameGlobal (Opt.Global h1 n1) (Opt.Global h2 n2) =
  h1 == h2 && n1 == n2


sameExprList :: [Opt.Expr] -> [Opt.Expr] -> Bool
sameExprList exprs1 exprs2 =
  case (exprs1, exprs2) of
    ([], []) ->
      True

    (e1 : rest1, e2 : rest2) ->
      sameExpr e1 e2 && sameExprList rest1 rest2

    _ ->
      False


sameMaybeExpr :: Maybe Opt.Expr -> Maybe Opt.Expr -> Bool
sameMaybeExpr maybeExpr1 maybeExpr2 =
  case (maybeExpr1, maybeExpr2) of
    (Nothing, Nothing) ->
      True

    (Just e1, Just e2) ->
      sameExpr e1 e2

    _ ->
      False


sameBranchList :: [(Opt.Expr, Opt.Expr)] -> [(Opt.Expr, Opt.Expr)] -> Bool
sameBranchList branches1 branches2 =
  case (branches1, branches2) of
    ([], []) ->
      True

    ((c1, b1) : rest1, (c2, b2) : rest2) ->
      sameExpr c1 c2 && sameExpr b1 b2 && sameBranchList rest1 rest2

    _ ->
      False



-- TREE TO DECIDER
--
-- Decision trees may have some redundancies, so we convert them to a Decider
-- which has special constructs to avoid code duplication when possible.


treeToDecider :: DT.DecisionTree -> Opt.Decider Int
treeToDecider tree =
  case tree of
    DT.Match target ->
        Opt.Leaf target

    -- zero options
    DT.Decision _ [] Nothing ->
        error "compiler bug, somehow created an empty decision tree"

    -- one option
    DT.Decision _ [(_, subTree)] Nothing ->
        treeToDecider subTree

    DT.Decision _ [] (Just subTree) ->
        treeToDecider subTree

    -- two options
    DT.Decision path [(test, successTree)] (Just failureTree) ->
        toChain path test successTree failureTree

    DT.Decision path [(test, successTree), (_, failureTree)] Nothing ->
        toChain path test successTree failureTree

    -- many options
    DT.Decision path edges Nothing ->
        let
          (necessaryTests, fallback) =
              (init edges, snd (last edges))
        in
          Opt.FanOut
            path
            (map (second treeToDecider) necessaryTests)
            (treeToDecider fallback)

    DT.Decision path edges (Just fallback) ->
        Opt.FanOut path (map (second treeToDecider) edges) (treeToDecider fallback)


toChain :: DT.Path -> DT.Test -> DT.DecisionTree -> DT.DecisionTree -> Opt.Decider Int
toChain path test successTree failureTree =
  let
    failure =
      treeToDecider failureTree
  in
    case treeToDecider successTree of
      Opt.Chain testChain success subFailure | failure == subFailure ->
          Opt.Chain ((path, test) : testChain) success failure

      success ->
          Opt.Chain [(path, test)] success failure



-- INSERT CHOICES
--
-- If a target appears exactly once in a Decider, the corresponding expression
-- can be inlined. Whether things are inlined or jumps is called a "choice".


countTargets :: Opt.Decider Int -> Map.Map Int Int
countTargets decisionTree =
  case decisionTree of
    Opt.Leaf target ->
        Map.singleton target 1

    Opt.Chain _ success failure ->
        Map.unionWith (+) (countTargets success) (countTargets failure)

    Opt.FanOut _ tests fallback ->
        Map.unionsWith (+) (map countTargets (fallback : map snd tests))


createChoices
    :: Map.Map Int Int
    -> (Int, Opt.Expr)
    -> ( (Int, Opt.Choice), Maybe (Int, Opt.Expr) )
createChoices targetCounts (target, branch) =
    if targetCounts ! target == 1 then
        ( (target, Opt.Inline branch)
        , Nothing
        )

    else
        ( (target, Opt.Jump target)
        , Just (target, branch)
        )


insertChoices
    :: Map.Map Int Opt.Choice
    -> Opt.Decider Int
    -> Opt.Decider Opt.Choice
insertChoices choiceDict decider =
  let
    go =
      insertChoices choiceDict
  in
    case decider of
      Opt.Leaf target ->
          Opt.Leaf (choiceDict ! target)

      Opt.Chain testChain success failure ->
          Opt.Chain testChain (go success) (go failure)

      Opt.FanOut path tests fallback ->
          Opt.FanOut path (map (second go) tests) (go fallback)
