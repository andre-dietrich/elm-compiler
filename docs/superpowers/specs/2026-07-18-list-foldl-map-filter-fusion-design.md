# Design Spec: `List.foldl` / `map` / `filter` Pipeline Fusion

## Motivation

Nutzen-check spike (session scratch `elm-fusion-spike`, 2026-07-18): a 4-function `Bench.elm`
compiled `--optimize` with the current fork compiler, exercising `xs |> List.filter p |> List.map f
|> ... |> List.foldl step acc` pipelines of length 2 through 5. Each stage of a real Elm pipeline
compiles to a *fully separate* traversal that allocates and fully materializes an intermediate
`List` before the next stage consumes it (confirmed in the generated JS — see `elm.js:4577-4611` in
the scratch project: `pipeline4` is `foldl.f(add, 0, filter.f(isBig, map.f(transform, filter.f(isValid,
xs))))`, three nested traversals for a 3-producer pipeline).

Hand-fused single-pass equivalents (same extracted closures, same list, one `for` loop walking
`.a`/`.b` exactly like the kernel's own `foldl`/`_List_toArray`) were benchmarked interleaved against
the real compiled baseline, N=200,000, 250 reps/process, 8 interleaved runs, checksums identical
throughout:

| stages | baseline med | fused med | speedup |
|---|---|---|---|
| 2 (filter→foldl) | 2088 ms | 252 ms | 8.3x |
| 3 (filter→map→foldl) | 2491 ms | 272 ms | 9.2x |
| 4 (filter→map→filter→foldl) | 4244 ms | 289 ms | 14.7x |
| 5 (filter→map→filter→map→foldl) | 5229 ms | 323 ms | 16.2x |

Baseline cost grows with stage count (each stage = one more full traversal + allocation); fused cost
is nearly flat (each stage only adds one more branch/call per element, no new allocation). This is a
different mechanism from every previous optimization in this fork (unwrapped-HOFs, TRMC, shape-padding,
arity-bypass): those all cut a *per-element constant factor*. This cuts the *number of traversals*,
and the win compounds with pipeline length — 5-10x larger than any single prior spike in this project.

Full derivation and prior-candidate rejections: see conversation session 2026-07-18 (Dict/Array
shape-padding ruled out as already covered by `[[adt-shape-padding-plan]]`; decision-tree path-caching
ruled out as low-value by reasoning through the existing `Jump`/`Leaf` sharing mechanism).

## Scope (V1)

**Trigger:** a saturated call to `elm/core`'s `List.foldl step acc listExpr`, where `listExpr` is
(possibly nested) `List.map`/`List.filter` calls terminating in some other expression (the "source").

**Producers fused:** `List.map`, `List.filter`, in any order, any chain length ≥ 1.

**Terminal consumer:** `List.foldl` only.

**Explicitly out of scope for V1 (fusion barriers — chain simply doesn't extend past these):**
- `List.filterMap` as a producer (needs `Maybe`-pattern codegen via `Optimize.Case`, not a plain
  `If` — deferred, see Future Work).
- `List.foldr`, `List.sum`, `List.length`, `List.product` as terminal consumers (each is a *different*
  known step+init pair over the same underlying kernel loop shape — mechanically similar, deferred
  to keep V1's diff small and this is not what was spiked).
- `List.sortBy`/`sortWith` (needs the whole list materialized — not a per-element streaming op),
  `List.take`/`drop` (need extra count state), `List.concatMap` (one-to-many, not one-to-zero-or-one),
  `List.map2..5` (multiple source lists), `List.reverse`, `List.append`, `List.indexedMap`.
- Bare producer chains with **no** terminal `List.foldl` (e.g. `List.map f (List.map g xs)` used
  directly, not as a fold's list argument) — no rewrite target to attach the fusion to in V1.

None of the "out of scope" cases are touched at all — the peel step (`peelListStage`) simply returns
`Nothing` the moment it hits an unrecognized shape, and the existing unmodified codegen path runs
for that unpeeled sub-expression, so an out-of-scope combinator anywhere in the chain never produces
wrong output, only a missed (safe) fusion opportunity.

## Why this is semantics-preserving

- Elm has no exceptions and no reordering-observable effects in pure code (no `Debug.log`-style
  side channel reordering risk beyond relative element order, which fusion does not change: elements
  are still processed in the same left-to-right order, `filter`'s predicate still evaluated before
  `map`'s transform for a given element, exactly as `filter p xs |> map f` implies).
- Every sub-expression that used to be evaluated exactly once (`step`, `acc`, each producer's
  function/predicate, the source list) is still evaluated exactly once in the fused form — no
  duplication, no elision.
- The rewrite is purely syntactic (matches `Can.VarForeign (ModuleName.Canonical "elm/core" "List")
  name` shapes) and therefore import-alias-agnostic — `import List exposing (foldl)`, `List.foldl`,
  and `import List as L; L.foldl` all canonicalize to the same `Can.VarForeign` identity before this
  pass runs, so surface syntax doesn't matter. It does **not** fire through an indirection (e.g. a
  user's local `myFoldl = List.foldl` alias called as `myFoldl step acc xs`), since that call site's
  `func` is `Can.VarLocal`/`Can.VarTopLevel`, not `Can.VarForeign List "foldl"` — same scope
  limitation every existing syntactic optimization in this compiler already has (`isListCons`,
  `kernelArity`), not a new risk class.
- **Correction (post-Task-1-review, 2026-07-19):** an earlier draft of this doc claimed the flat JS
  seen in the spike's compiled output (`$elm$core$List$foldl.f(step, acc, $elm$core$List$filter.f(p,
  xs))`) proved `|>` chains reach `Optimize.Expression` as flat, fully-saturated `Can.Call` nodes.
  That was **wrong** — verified by reading the actual source. `x |> f` and `f <| x` canonicalize to
  `Can.Binop _ home "apR"/"apL" _ left right` (`Canonicalize/Expression.hs`'s generic `toBinop`, no
  special-casing for pipe operators), and `Optimize.Expression.hs`'s existing `Can.Binop` handling
  (unchanged, lines 93-104) lowers *every* non-`toPrimBinop` binop — `apL`/`apR` included, since
  neither is in that table — to a generic `Opt.Call (registerGlobal home name) [left, right]`. The
  flat JS is real, but it's produced *later*, in `Generate.JavaScript.Expression.hs`'s `apply`
  (`Opt.Call f args -> Opt.Call f (args ++ [value])`, invoked from the `"apR"`/`"apL"` codegen cases)
  — a `Generate`-phase, JS-codegen-time merge that runs on an already-built `Opt.Expr`, strictly after
  `Optimize.Expression.optimize` has finished. A pass running *inside* `optimize` (as this one does)
  never sees that merge; it still sees the nested `apR`/`apL` `Opt.Call`-of-a-partial-call shape. The
  mechanism below (`collectApplication`) does at the `Can.Expr` level, one phase earlier, exactly what
  `Generate`'s `apply` does at the `Opt.Expr` level — so this pass sees the same flattened shape
  `apply` would have produced, without waiting for `Generate` to do it.

## Where this lives

Entirely inside `Optimize.Expression.hs`'s `optimize` function, as one new guarded case-alternative
matched with a wildcard pattern (`_`) at the very top of the `case expression of` list — not scoped
to `Can.Call` alone, since the trigger shape (`List.foldl` applied to 3 arguments) can arrive as an
ordinary `Can.Call` *or* as a `Can.Binop` chain on `apL`/`apR` (`|>`/`<|`), and a case alternative can
only pattern-match one shape at a time. Haskell tries case alternatives top-to-bottom and falls
through to the next (here, the pre-existing `Can.Call`/`Can.Binop` alternatives, unmodified) on guard
failure — `PatternGuards` is already enabled at the top of this file. No new `AST.Optimized`
constructor, no `.elmo`/binary format change (unlike TRMC or ADT-shape-padding): the rewrite produces
completely ordinary `Opt.Call`/`Opt.Function`/`Opt.If` nodes, identical in shape to what hand-written
Elm calling `List.foldl` with a lambda would produce. This means the *entire* existing downstream
pipeline — arity bypass, `$unwrapped` HOF redirection, everything in `Generate.Mode`/`Generate.JavaScript`
— applies to the synthesized call for free, with zero codegen changes.

**Mode:** uniform Dev + Prod, matching the TRMC and prim-binop-specialization precedent (this is a
pure Can→Opt rewrite, not conditioned on any `Mode.Prod`-only whole-program table, so it doesn't
touch the CLAUDE.md "Prod must not change Dev" contract — that contract is about the Prod-only
`shortenFieldNames`/`computeArities` tables leaking into Dev, not about whether *any* new optimization
may change Dev output at all; TRMC already changes Dev output the same way).

## Mechanism

```haskell
-- Normalizes ordinary application (`Can.Call`) and pipe-operator application
-- (`|>`/`<|`, i.e. `Can.Binop` on `Basics.apR`/`apL`) into one shape: the
-- ultimate callee expression and its fully gathered argument list, in the
-- same left-to-right order the arguments would appear in ordinary prefix
-- call syntax. `x |> f` and `f <| x` both normalize identically to what
-- `f x` would. This mirrors, one phase earlier, exactly what
-- `Generate.JavaScript.Expression`'s `apply` (`Opt.Call f args -> Opt.Call f
-- (args ++ [value])`) does to `Opt.Expr` at codegen time -- see "Why this is
-- semantics-preserving" above for why relying on that later merge doesn't
-- work for a pass running inside `optimize`.
collectApplication :: Can.Expr -> (Can.Expr, [Can.Expr])
collectApplication expr@(A.At _ expression) =
  case expression of
    Can.Call func args ->
      (func, args)

    Can.Binop _ home name _ left right
      | home == ModuleName.basics, name == "apR" ->
          let (callee, args) = collectApplication right in (callee, args ++ [left])
      | home == ModuleName.basics, name == "apL" ->
          let (callee, args) = collectApplication left in (callee, args ++ [right])

    _ ->
      (expr, [])


-- One layer of a producer chain peeled off a List.foldl's list argument.
-- Carries the *unoptimized* Can.Expr for the function/predicate so it can
-- be optimize'd in the right place (inside the synthesized step, alongside
-- fresh local names, not hoisted out).
data ListStage
  = StageMap Can.Expr Can.Expr     -- ^ f, inner list expr
  | StageFilter Can.Expr Can.Expr  -- ^ p, inner list expr


-- Nothing => not a recognized producer shape (source list, or a fusion
-- barrier like sortBy/take/concatMap/filterMap) => stop peeling here.
-- Uses collectApplication so `xs |> List.filter p` and `List.filter p xs`
-- both peel identically.
peelListStage :: Can.Expr -> Maybe ListStage
peelListStage expr =
  case collectApplication expr of
    (A.At _ (Can.VarForeign home name _), [f, inner])
      | home == ModuleName.list, name == "map"    -> Just (StageMap f inner)
      | home == ModuleName.list, name == "filter" -> Just (StageFilter f inner)
    _ ->
      Nothing


stageInner :: ListStage -> Can.Expr
stageInner (StageMap _ inner)    = inner
stageInner (StageFilter _ inner) = inner


-- Peels as many layers as match, outermost (closest to the foldl) first.
-- Returns the peeled stages plus whatever expression peeling stopped at
-- (the true source list, or a barrier we don't understand).
peelChain :: Can.Expr -> ([ListStage], Can.Expr)
peelChain expr =
  case peelListStage expr of
    Nothing    -> ([], expr)
    Just stage -> let (rest, source) = peelChain (stageInner stage) in (stage : rest, source)


-- A step continuation: given the current raw element and the current
-- accumulator (both already-optimized Opt.Expr), produces the new
-- accumulator. Composing these left-to-right over `stages` (outermost
-- stage wraps last) reconstructs the original evaluation order: filter's
-- predicate is checked on the *original* element before map's transform
-- is ever applied, exactly as `filter p xs |> map f` implies.
type StepK = Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr


baseStepK :: Opt.Expr -> StepK
baseStepK optStep elemExpr accExpr =
  pure (Opt.Call optStep [elemExpr, accExpr])


wrapStage :: Hints -> Cycle -> StepK -> ListStage -> Names.Tracker StepK
wrapStage hints cycle inner stage =
  case stage of
    StageMap f _ ->
      do  optF <- optimize hints cycle f
          pure $ \elemExpr accExpr -> inner (Opt.Call optF [elemExpr]) accExpr

    StageFilter p _ ->
      do  optP <- optimize hints cycle p
          pure $ \elemExpr accExpr ->
            do  thenBranch <- inner elemExpr accExpr
                pure (Opt.If [(Opt.Call optP [elemExpr], thenBranch)] accExpr)
```

Integration point in `optimize`'s `case expression of`: a new **wildcard**-guarded alternative
inserted as the *first* alternative in the whole list (before `Can.VarLocal name -> ...` and
everything else) — it must be a wildcard, not `Can.Call func args`, because the trigger shape can
arrive as `Can.Call` (prefix syntax) or `Can.Binop` (`|>`/`<|` syntax), and `collectApplication`
normalizes both. On guard failure it falls through to whichever alternative actually matches
`expression` (`Can.Call`'s existing `toPrimCall` path, `Can.Binop`'s existing `toPrimBinop` path, or
any other constructor), all unmodified:

```haskell
_
  | (A.At _ (Can.VarForeign home name _), [stepArg, accArg, listArg]) <-
      collectApplication (A.At region expression)
  , home == ModuleName.list, name == "foldl"
  , (stages@(_:_), source) <- peelChain listArg
  ->
      do  optStep    <- optimize hints cycle stepArg
          optAcc     <- optimize hints cycle accArg
          optSource  <- optimize hints cycle source
          composed   <- foldM (wrapStage hints cycle) (baseStepK optStep) stages
          xName      <- Names.generate
          accName    <- Names.generate
          body       <- composed (Opt.VarLocal xName) (Opt.VarLocal accName)
          optFoldl   <- Names.registerGlobal ModuleName.list "foldl"
          pure $ Opt.Call optFoldl
            [ Opt.Function [xName, accName] body
            , optAcc
            , optSource
            ]
```

(`region` and `expression` are already bound by `optimize`'s own argument pattern,
`optimize hints cycle (A.At region expression) = case expression of ...`, so `A.At region expression`
just reconstructs the original whole `Can.Expr` to hand to `collectApplication`.)

Note `foldM` folds `stages` **left-to-right** (outermost/closest-to-`foldl` stage first), which is
the direction that reconstructs correct evaluation order — verified by hand-tracing the 2-stage case
`foldl step acc (map f (filter p xs))`: `stages = [StageMap f _, StageFilter p _]`;
`foldM` produces `wrapStage (wrapStage baseStepK (StageMap f _)) (StageFilter p _)`, i.e.
`composed(x,acc) = if p(x) then step(f(x),acc) else acc` — filter's predicate on the raw element,
map's transform only on survivors, exactly matching `filter p xs |> map f |> foldl step acc`.

## Verification protocol

Reuse the spike's scratch project (`elm-fusion-spike`, already has `pipeline2`..`pipeline5` covering
1 through 4 producer stages, all inside V1 scope since none use `filterMap`/`sortBy`/etc.) — no Elm
source changes needed for the happy path.

1. Build "before" (current HEAD) and "after" (with this change) compiler binaries, same pattern as
   `kernel-list-shape-padding`'s plan Task 2 (`git worktree add` for "before", fresh `ELM_HOME` volume).
   **Gotcha found during Task 2 execution (2026-07-19):** when compiling the *same* scratch project
   with *two different compiler binaries*, also clear the project-local `elm-stuff/` directory
   between compiles (`rm -rf elm-stuff` or the usual root-owned-cache Docker workaround). Elm's own
   staleness check (`Details`/`File.Time`, mtime-based) has no notion of *which compiler binary*
   produced a cached `.elmo`/`.elmi` — only whether the *source file* changed — so recompiling
   unchanged `Bench.elm` with a different binary in the same directory silently reuses the previous
   binary's cached output. This is a different cache than the `ELM_HOME` package-cache gotcha CLAUDE.md
   already documents (that one is about `elm/core` etc.; this one is about the project's own module).
   Symptom if hit: the "before" binary's compiled output looks identical to "after"'s (both show the
   fused shape) even though "before" doesn't have the fusion pass at all — caught here because the
   structural check in step 2 immediately looked wrong for the pre-fusion compiler.
2. Structural check: grep the "after" `--optimize` output for `pipeline4`'s body — expect **zero**
   occurrences of `$elm$core$List$map.f`/`$elm$core$List$filter.f` *inside that one function's body*
   (function-scoped grep, not whole-file — the stdlib itself still defines/uses `map`/`filter`
   elsewhere), and exactly one `$elm$core$List$foldl` call. **This is the load-bearing regression
   test for the `|>` desugaring gap found in Task 1 review** (2026-07-19): every `pipelineN` in
   `Bench.elm` is written with `|>` chains, not prefix calls — the pre-fix code compiled clean and
   was "spec compliant" against the original (flawed) design, but this exact grep would have shown
   `pipeline4`'s body still containing `List.map`/`List.filter` calls, because the fusion guard never
   matched `Can.Binop`-shaped call sites at all. If this check ever regresses, suspect the
   `collectApplication` normalization, not the peeling/composition logic below it.
3. Correctness: checksum match between "before" and "after" for `pipeline2..5` across list sizes
   `0, 1, 2, 3, 10, 137, 10000` (mirrors the spike's own correctness sweep) plus an all-filtered-out
   case (predicate always `False`) and a single-element case.
4. Negative control: add one `myFoldl = List.foldl` local-alias call site to the scratch module,
   confirm it still produces the correct (unfused, but correct) result — proves the "no false
   positives through indirection" scope limit doesn't silently break code, it just doesn't optimize it.
5. Dev-mode: compile without `--optimize`, confirm still produces correct checksums (this rewrite is
   unconditional on `Mode`, unlike shape-padding).
6. Re-run the interleaved timing harness (`drive.js`/`run-one.js` from the spike, pointed at the real
   "after" compiler's output instead of the hand-patched `fused.js`) and confirm the speedup lands in
   the same ballpark the hand-patch spike found (8-16x growing with stage count) — this is the step
   that upgrades the spike's *ceiling* estimate into a *real, compiler-produced* measurement.

## Future work (not V1)

- `List.filterMap` as a producer (needs `Optimize.Case`/decision-tree codegen for the `Maybe` match,
  not a plain `If`).
- `List.foldr`, `List.sum`, `List.length`, `List.product` as additional terminal consumers (each is
  a known step+init pair over the same kernel loop shape).
- Bare producer-chain fusion with no terminal fold (`List.map f (List.map g xs)` → `List.map (f << g)
  xs`) — useful on its own, not exercised by this spike.
- `List.sortBy`/`take`/`drop`/`concatMap`/`map2..5` as fusion barriers with their own attach points
  (would need per-combinator design, not just "unrecognized == stop").
- **Double-evaluation of a mapped value across a following filter** (found during Task 2
  verification, 2026-07-19): `wrapStage`'s `StageFilter` case uses its `elemExpr` parameter twice —
  once in its own predicate test, once via the `inner` continuation it calls — so for a filter stage
  that sits between a map stage and `foldl`, the mapped value gets recomputed once per such filter
  test. Confirmed in real compiled output: `pipeline4`'s (`filter isValid |> map transform |> filter
  isBig |> foldl`) fused body calls `transform(_v0)` twice (once for the `isBig` test, once for the
  addition). Semantically correct (Elm has no side effects to duplicate, so recomputation ≠ wrong
  result) but real extra work for an expensive map function — growth is linear in the number of
  filter stages downstream of a given map (not exponential; each `wrapStage` call site only calls its
  `inner` continuation once). A follow-up could introduce a `Opt.Let`-bound temporary for the mapped
  value the first time a `StageMap` is followed (moving toward `foldl`) by at least one `StageFilter`,
  so it's computed once and reused.
