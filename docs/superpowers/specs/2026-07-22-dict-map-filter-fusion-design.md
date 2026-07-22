# Design Spec: `Dict.foldl` / `map` / `filter` Pipeline Fusion

## Motivation

Nutzen-check spike (session scratch `dict-fusion-spike`, 2026-07-22, memory:
`dict-map-filter-fusion-spike.md`): `elm/core`'s `Dict` currently compiles `dict |> Dict.map f |>
Dict.filter pred |> Dict.foldl step acc` into three fully separate traversals, confirmed by reading
the generated `--optimize` JS (`elm.js` in the spike's scratch dir). Discovered as a follow-up
candidate while answering the user's general "can Dict's map/filter be fused like List/Array's?"
question — see [[array-chain-fusion-spike]] and [[list-foldl-fusion-plan]] for the prior two data
points this generalizes from.

One `elm/core`-specific aggravating factor, found while reading the generated JS for the spike:
`Dict.map` is already TRMC-optimized (mutable-cell construction on the right spine, same technique
as List's TRMC work) but still builds a **full new tree** (n fresh `RBNode_elm_builtin` objects,
one per key). Worse, `Dict.filter` is **not** implemented tree-natively at all: it goes
`Dict.foldl` (full traversal) → `Dict.insert` per surviving key (`elm/core`'s red-black insert,
`O(log n)` with rebalancing via `balance`). So the naive 3-stage pipeline does: tree-traversal
+ tree-rebuild (`map`, `O(n)`) → tree-traversal + `O(n log n)` insert-rebuild (`filter`) →
tree-traversal (`foldl`) — this is strictly more expensive than either List's or Array's naive
pipeline, both of whose `filter` is linear.

Hand-simulated single-pass equivalent (same closures, walking `node.b`/`node.c`/`node.d`/`node.e` —
the key/value/left/right fields `Dict.foldl` itself already destructures — exactly once, applying
`map`'s function then `filter`'s predicate then `foldl`'s combiner inline, zero intermediate `Dict`)
was benchmarked interleaved against the real compiled baseline, `--optimize`, N ∈
{1000, 10000, 100000, 1000000}, 15 interleaved reps/size after 1 discarded warmup pair, 2 full runs,
scalar result identical on every run (verified by hand for N=1000: 333333):

| n | naive avg | fused avg | speedup |
|---|---|---|---|
| 1,000 | ~7ms | ~0.3ms | ~22x |
| 10,000 | ~40ms | ~1.7ms | ~24x |
| 100,000 | ~463ms | ~25ms | ~18x |
| 1,000,000 | ~5,310ms | ~248ms | ~21x |

Consistent 18-25x across both runs and all four sizes — the largest fusion win measured in this
project to date (List: 6.4-14x, Array: 1.8-5.6x), because eliminating the pipeline doesn't just
remove redundant traversals/allocation, it removes `filter`'s entire `O(n log n)`
insert-and-rebalance cost.

## Scope (Dict V1 — deliberately narrow, mirrors List's and Array's own incremental history)

**Trigger:** a saturated call to `elm/core`'s `Dict.foldl step acc dictExpr`, where `dictExpr` is
(possibly nested) `Dict.map`/`Dict.filter` calls terminating in some other expression (the
"source").

**Producers fused:** `Dict.map`, `Dict.filter`, any order, any chain length ≥ 1.

**Terminal consumer:** `Dict.foldl` only.

**Explicitly out of scope for this plan:**

- `Dict.foldr` as a terminal consumer — not proposed, even though it's plausibly *safer* here than
  in List's case: `Dict.foldr` recurses on the tree's height (`O(log n)` stack depth, balanced
  tree) rather than on `n` (List's foldr recurses on every cons cell, which is why
  [[list-foldr-fusion-spike]] found naive fusion crashes past N~20k). That plausibility is not a
  measurement — this plan doesn't touch `Dict.foldr` until it's separately spiked.
- `Dict.toList`/`keys`/`values` as terminators — all three are themselves defined via `Dict.foldr`
  in `elm/core`, so they're a real future candidate (mirrors List's `sum`/`length`/`product`
  extension, [[list-fusion-v2-spike]]) but unspiked, so out of scope here.
- Bare producer chains with **no** terminal `Dict.foldl` (e.g. `Dict.map f (Dict.filter pred dict)`
  used directly) — unlike List's [[bare-producer-chain-fusion-spike]], which could synthesize
  output via `List.cons` (O(1) kernel-level cell construction), a bare Dict producer chain would
  need to build a *new* tree. `Dict.map` alone can reuse its existing TRMC mutable-cell trick, but
  a bare chain ending in `Dict.filter` still needs *some* way to drop nodes and preserve red-black
  balance invariants, which is mechanically different from a fold's simple accumulator-threading
  and not validated by any spike. Left for a future, separately-spiked plan.
- Any change to `elm/core` itself (the red-black tree kernel) — not needed for this plan and not
  attempted; the fusion only rewrites the call site, exactly as List's and Array's did.

None of the "out of scope" cases are touched at all — `peelDictStage` (see below) simply returns
`Nothing` the moment it hits an unrecognized shape (including `Dict.foldr`, since that name is
never checked), and the existing unmodified codegen path runs for that unpeeled sub-expression. An
out-of-scope combinator anywhere in the chain never produces wrong output, only a missed (safe)
fusion opportunity — same guarantee [[list-foldl-fusion-plan]] and [[array-chain-fusion-spike]]
established.

## Mechanism: parallel definitions, not a generalization

`compiler/src/Optimize/Expression.hs` already has, from the List/Array fusion work: `ListStage`
(`StageMap`/`StageFilter`/`StageFilterMap`), `StepK`/`baseStepK`/`wrapStage`, and
`collectApplication`. Unlike Array's own extension (which reused `ListStage`/`StepK` verbatim,
since `Array.map`/`filter`/`foldl` all carry a single value with no extra chain-invariant
argument), Dict's producers/terminator all carry the **key** as an additional argument that stays
unchanged through the whole chain (`Dict.map : (k -> a -> b) -> ...`, `Dict.filter :
(comparable -> v -> Bool) -> ...`, `Dict.foldl : (k -> v -> b -> b) -> ...`) — a shape `ListStage`/
`StepK` has no slot for. Generalizing `ListStage`/`StepK` to carry an optional key would mean
touching and re-verifying List's and Array's four already-shipped call sites for a change that
only this new, fifth one needs — the same reasoning [[array-chain-fusion-spike]] used to justify
its own parallel (not generalized) definitions.

This plan adds:

- `DictStage = DStageMap Can.Expr Can.Expr | DStageFilter Can.Expr Can.Expr` — f/pred, inner dict
  expr. No `DStageFilterMap` (no `Dict.filterMap` exists in `elm/core`).
- `peelDictStage :: Can.Expr -> Maybe DictStage` — same shape as `peelListStage`, matching
  `ModuleName.dict`/`"map"`/`"filter"` via `collectApplication` (so `|>`/`<|` pipelines are
  recognized identically to the List/Array passes).
- `peelDictChain :: Can.Expr -> ([DictStage], Can.Expr)` — same recursion shape as `peelChain`.
- `type DictStepK = Opt.Expr -> Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr` — key, value, acc →
  new acc (three `Opt.Expr` arguments where List's `StepK` has two, to carry the key through).
- `baseDictStepK :: Opt.Expr -> DictStepK` — `baseDictStepK optStep keyExpr elemExpr accExpr =
  pure (Opt.Call optStep [keyExpr, elemExpr, accExpr])`.
- `wrapDictStage :: Hints -> Cycle -> DictStepK -> DictStage -> Names.Tracker DictStepK`:
  - `DStageMap f`: `optF <- optimize hints cycle f; pure $ \k v acc -> inner k (Opt.Call optF [k,
    v]) acc` (applies `f` to `(key, value)`, key unchanged, passes mapped value onward).
  - `DStageFilter p`: `optP <- optimize hints cycle p; pure $ \k v acc -> do thenBranch <- inner k v
    acc; pure (Opt.If [(Opt.Call optP [k, v], thenBranch)] acc)` (checks predicate on `(key,
    current value)`, same `If`-guard shape as `wrapStage`'s `StageFilter` case).
- `buildFusedDictFold :: Hints -> Cycle -> DictStepK -> Opt.Expr -> [DictStage] -> Can.Expr ->
  Names.Tracker Opt.Expr` — composes stages via `foldM (wrapDictStage hints cycle) base stages`
  (same `foldM` composition order as `buildFusedFold`, so a filter checks its predicate against
  whatever value an outer map already produced — matching `dict |> Dict.map f |> Dict.filter pred`
  evaluation order), then emits one `Names.registerGlobal ModuleName.dict "foldl"` call over
  `source` with the synthesized 3-arg step.
- One new guarded alternative in `optimize`'s dispatch (alongside the existing List/Array `foldl`
  guards): `home == ModuleName.dict, name == "foldl"`, `(stages@(_:_), source) <- peelDictChain
  dictArg`.

## Why this is semantics-preserving

- **Order preservation, proved directly from the BST invariant**: `Dict.foldl`/`foldr` traverse a
  tree in ascending-key order, and *every* valid binary search tree containing a given key set
  produces that same ascending order under in-order traversal — regardless of shape, color, or how
  many rotations `balance`/`insert` performed to get there. This is a strictly simpler argument
  than Array's (which had to reason through `Array.filter`'s `foldr`-then-`cons`-then-`fromList`
  detour): `Dict.map` never touches keys or tree shape (only the value at each existing node), so
  the composed pipeline's final `Dict.foldl` visits surviving keys in the same ascending order the
  fused version's direct walk over the *original* tree does, unconditionally.
- No *observable* change for total, effect-free producer functions — the common case. A map whose
  output feeds a following filter is emitted at both the predicate call site and the pass-through
  to the next stage (`wrapDictStage`'s `DStageFilter` case calls `inner` with the same `elemExpr`
  it just tested), so that producer's function is called twice per surviving element in the fused
  form, not once. This is identical, pre-existing behavior inherited from `wrapStage`'s own
  `StageFilter` case (same argument as [[list-foldl-fusion-plan]]'s and
  [[array-chain-fusion-spike]]'s) — not a Dict-specific regression — and is unobservable for pure,
  terminating functions, which is why the order-sensitive correctness check still passes. It would
  only be observable for a diverging/crashing function or `Debug.log` in a Dev build.
- Purely syntactic, import-alias-agnostic (matches `Can.VarForeign (ModuleName.Canonical
  "elm/core" "Dict") name` shapes, canonicalized before this pass runs) — does not fire through a
  local alias (e.g. `myFilter = Dict.filter`), same scope limitation every existing syntactic
  optimization in this compiler already has.
- Not `Mode`-gated (runs identically in Dev and Prod) — a pure `Optimize.Expression`-level AST
  rewrite, same as every List/Array fusion pass before it.
- No new `AST.Optimized` constructor, no `.elmo`/`.elmi` format change — reuses `Opt.Call`/
  `Opt.Function`/`Opt.If`/`Opt.VarLocal`/`Opt.Int`, all already emitted by the List/Array fusion
  passes.

## Why this doesn't touch `elm/core`

Same reasoning as Array's plan: this fusion only rewrites the **call site** —
`dict |> Dict.map f |> Dict.filter pred |> Dict.foldl step acc` becomes a single call to the
*existing, unmodified* `Dict.foldl` with a synthesized composed step. `Dict.foldl`, `Dict.map`, and
`Dict.filter` themselves are untouched; the two intermediate calls simply never get emitted. The
red-black tree kernel (`RBNode_elm_builtin`/`RBEmpty_elm_builtin`, `balance`, `insertHelp`) is
never modified, which is also why the eliminated `Dict.filter`-via-`insert` cost is pure upside
with no correctness risk to the tree's balance invariants — the fused version never calls `insert`
at all, so there's nothing to rebalance.

## Verification plan

Same methodology as the List and Array fusion plans: build the patched compiler, compile the
spike's `Main.elm` pipeline (`dict |> Dict.map f |> Dict.filter pred |> Dict.foldl step acc`) with
`--optimize`, diff the generated JS to confirm a single `Dict.foldl` call site with no intermediate
`Dict.map`/`Dict.filter` calls, then re-run the Node benchmark harness against the **real**
(now-fused) compiler output across the same N range to confirm the spike's hand-simulated 18-25x
holds end-to-end through the actual compiler, not just the hand-written approximation.
