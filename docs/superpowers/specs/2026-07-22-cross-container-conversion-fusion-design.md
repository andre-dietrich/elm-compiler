# Design Spec: Cross-Container Conversion Fusion (`Dict.toList`/`keys`/`values`, `Set.toList`,
# `Array.toList` feeding `List.foldl`)

## Motivation

Follow-up to the already-shipped [[list-foldl-fusion-plan]], [[array-chain-fusion-spike]],
[[dict-map-filter-fusion-spike]] and [[set-filter-foldl-fusion-plan]] — each of those fuses `map`/
`filter` chains *within* a single container's own `foldl`. User question: does fusion also help at
the *boundary* between two containers, e.g. `dict |> Dict.toList |> List.foldl step acc`? Audit of
`Optimize/Expression.hs` found it does not: `peelListStage`/`peelChain` only recognize
`List.map`/`List.filter`/`List.filterMap`; once peeling reaches `Dict.toList d`, `Dict.keys d`,
`Dict.values d`, `Set.toList s`, or `Array.toList a`, it stops and treats the expression as an
opaque list value — the conversion still builds a real intermediate list before `List.foldl`
(possibly itself already fused with any `List.map`/`filter` stages sitting on top of it, thanks to
the shipped List fusion, but the conversion's own list-build pass survives untouched either way).

**Empirical validation** (spike, hand-patched, real Elm/core-derived runtime representations,
`cross-container-conversion-fusion-spike.md`): 1.16x-3.15x across `Dict.toList`/`Dict.values`/
`Set.toList`/`Array.toList`, growing with `n`, zero correctness mismatches across 4 cases × 4 sizes
using an order-sensitive rolling-hash checksum (a plain sum would have silently passed even with a
traversal-order bug). Also confirmed: chaining additional `List.map`/`List.filter` stages between
the conversion and the `foldl` does **not** make the win bigger (1.36x-3.37x, statistically
indistinguishable from the bare-conversion numbers) — those stages are *already* collapsed into a
single pass by the shipped `list-foldl-fusion-plan` regardless of what sits underneath them as the
chain's base, so this new pass only ever removes the one remaining pass: the conversion's own
list-build.

## Semantics: why this is safe

All five recognized conversions are themselves pure `foldr`/`foldl`-style projections in `elm/core`
(`/root/.elm/0.19.2/packages/elm/core/1.0.5/src/{Dict,Set,Array}.elm`) that preserve the target
container's natural traversal order:

- `Dict.toList d = foldr (\k v l -> (k,v)::l) [] d` — ascending by key.
- `Dict.keys`/`Dict.values` — same `foldr`, projected to just the key or just the value.
- `Set.toList (Set_elm_builtin dict) = Dict.keys dict` — Set is `Can.Unbox`-erased to its
  underlying `Dict` at runtime (confirmed in [[set-filter-foldl-fusion-spike]]), so this is exactly
  the `Dict.keys` case with a different static type.
- `Array.toList arr = foldr (::) [] arr` — ascending by index.

Because `List.foldl` walks its list argument strictly left-to-right, and each of the five
conversions produces a list in exactly the ascending order its own `foldl` would already visit
nodes in, the following four rewrites are semantically identical for any total, effect-free `step`:

```
List.foldl step z (Dict.toList d)   ==  Dict.foldl  (\k v acc -> step (k, v) acc) z d
List.foldl step z (Dict.keys   d)   ==  Dict.foldl  (\k _ acc -> step k       acc) z d
List.foldl step z (Dict.values d)   ==  Dict.foldl  (\_ v acc -> step v       acc) z d
List.foldl step z (Set.toList  s)   ==  Set.foldl   step z s
List.foldl step z (Array.toList a)  ==  Array.foldl step z a
```

(`Set.toList`/`Array.toList` need no per-argument adapter — `Set.foldl`/`Array.foldl` already share
`List.foldl`'s exact 2-argument step shape.) This composes with the existing `List.map`/`filter`/
`filterMap` peeling unchanged: those stages operate on whatever "element" the conversion produces
(a `(k,v)` tuple for `Dict.toList`, a bare key/value otherwise) exactly as they would on a literal
list of the same shape, so a chain like `Dict.toList d |> List.map f |> List.filter p |> List.foldl
g z` fuses to one `Dict.foldl` call with `f`/`p`/`g` all composed into its step, no intermediate
list at any point.

## Mechanism

New, additive section in `Optimize/Expression.hs`, reusing `ListStage`/`StepK`/`wrapStage`/
`baseStepK`/`peelChain` **unchanged** (unlike the Dict/Set sections, this one needs no new stage or
step-continuation type — the only new pieces are (a) recognizing the five conversions as a
`peelChain` base, and (b) picking a different terminator global + argument-adapter once one is
found):

- `CrossBase = CBDictToList Can.Expr | CBDictKeys Can.Expr | CBDictValues Can.Expr | CBSetToList
  Can.Expr | CBArrayToList Can.Expr` — one constructor per recognized conversion, each carrying the
  converted-from container expression.
- `peelCrossBase :: Can.Expr -> Maybe CrossBase` — matches a saturated 1-argument call (via
  `collectApplication`, so `|>`/`<|` and ordinary application both work, same as every other
  peeling function in this file) to `Dict.toList`/`Dict.keys`/`Dict.values`/`Set.toList`/
  `Array.toList`. Nothing for anything else (including a local alias, or `Dict.foldr`-based
  hand-written conversions this pass doesn't special-case).
- `buildFusedCrossFold :: Hints -> Cycle -> Opt.Expr -> Opt.Expr -> [ListStage] -> CrossBase ->
  Names.Tracker Opt.Expr` — takes the user's already-`optimize`d step function (`optStep`) as a raw
  `Opt.Expr`, generates a fresh name for it, and composes `stages` via the existing `wrapStage`
  against `baseStepK (Opt.VarLocal stepName)` (not `baseStepK optStep` directly — see "Post-ship fix"
  below for why), then dispatches on `CrossBase` to emit either a 3-argument `Dict.foldl` call
  (project the fresh `keyName`/`valName` into a tuple, just the key, or just the value, depending on
  which of `CBDictToList`/`CBDictKeys`/`CBDictValues` matched) or a 2-argument `Set.foldl`/
  `Array.foldl` call (no projection needed). The whole result is wrapped in `Opt.Let (Opt.Def
  stepName optStep) result`, binding the user's step function exactly once, outside the per-element
  callback.

### Post-ship fix: hoisting `optStep` via `Opt.Let` (regression found and fixed same day)

The first version of `buildFusedCrossFold` took a pre-built `StepK` (`baseStepK optStep`) and spliced
`Opt.Call optStep [elemExpr, accExpr]` directly into the per-element callback's body. Real-compiler
verification (two-binary build, structural JS check, order-sensitive correctness check, interleaved
timing) found this was **1.3x-1.4x slower** than the unfused baseline for 4 of the 5 base conversions
(`Dict.keys`/`Dict.values`/`Set.toList`/`Array.toList` — only `Dict.toList`'s pair case and a
`map`/`filter`-chained case still won). Root cause: when `optStep` is a literal `Opt.Function` (the
common case — the user wrote an inline lambda), a nested `Opt.Call optStep [...]` sitting inside
another synthesized function's body is a callee shape `Generate/JavaScript/Expression.hs`'s call-site
dispatch does not recognize (it only special-cases `Opt.VarGlobal`/`Opt.VarLocal` callees with a
statically known arity, via `Generate/Mode.hs`'s arity table); it falls back to the generic dispatch,
which wraps the literal `Opt.Function` in a fresh `F2(...)` closure and calls it via `A2` — **on every
element**, since the wrapping sits inside the per-element callback's JS body. This is strictly worse
than the *unfused* baseline, where the same lambda sits as `List.foldl`'s literal argument and gets
the existing `$unwrapped`/no-wrap treatment for free.

Fix: bind `optStep` once via `Opt.Let (Opt.Def stepName optStep) result`, outside the per-element
callback, and have the callback call `Opt.VarLocal stepName` instead of `optStep` directly (via
`baseStepK (Opt.VarLocal stepName)`). This reuses already-shipped, already-tested machinery
unchanged: `Generate/JavaScript/Expression.hs`'s `extendWithLocalArity` recognizes `Opt.Def name
(Opt.Function args _)` and records the local's arity, so `generateDirectLocalCall` compiles calls to
`stepName` as a direct `.f(...)` call with no `A2` at all when `optStep` is a literal lambda; when
it isn't (e.g. a named top-level function reference), the hoist still avoids re-evaluating `optStep`
once per element, which is no worse than before. Scoped entirely to `buildFusedCrossFold` and its
call site — `baseStepK`/`wrapStage`/`StepK` and the other four `buildFused*` functions (shared with
the already-shipped List/Array/Dict/Set fusions) were not touched, since those fusions never trigger
with zero stages and are not implicated by this regression. Real-compiler re-verification after the
fix confirmed all 6 benchmarked patterns now show genuine speedups: 1.5x-2.55x, with
`dictKeysFoldl`/`dictValuesFoldl`/`setToListFoldl`/`arrayToListFoldl` flipping from ~0.7-0.9x
(slower) to 1.5x-1.8x, and the two already-winning patterns (`dictToListFoldl`,
`chainedDictToListFoldl`) improving or holding steady at 2.1x-2.55x.
- New guard clause in `optimize`, added **immediately before** the existing `home ==
  ModuleName.list, name == "foldl"` guard (so it takes priority when applicable — Haskell tries
  guards top-to-bottom, first match wins): matches `List.foldl stepArg accArg listArg`, peels
  `listArg` via the existing `peelChain` (stages may be **empty** — unlike every other fusion guard
  in this file, this one is not gated on `stages@(_:_)`, since even a bare `List.foldl step acc
  (Dict.toList d)` with no `map`/`filter` in between is worth fusing), then requires `peelCrossBase
  source` to succeed. If it doesn't, guard evaluation falls through to the untouched, already-
  shipped `stages@(_:_)`-gated List guard below, so ordinary `list |> List.map f |> List.foldl g z`
  (a real list, not a conversion) behaves exactly as it does today.

No new `AST.Optimized` constructor (reuses `Opt.Call`/`Opt.Function`/`Opt.Tuple`, all pre-existing),
no `.elmo` format change, no `Generate.*` change, no `elm/core` change, not `Mode`-gated (runs
identically in Dev and Prod, like every fusion pass before it).

## Explicitly out of scope for this plan

- `Dict.fromList`/`Set.fromList`/`Array.fromList` (the reverse direction). These build a genuinely
  new tree/trie structure — not a mere traversal-order projection like `toList`/`keys`/`values` — so
  eliminating their intermediate list would need a fundamentally different mechanism (bulk
  construction from a statically-known-sorted source), never spiked, not attempted here.
- `List.sum`/`List.product`/`List.length` terminators reaching through one of these five
  conversions (e.g. `List.sum (Dict.values d)`). Plausible follow-up, same underlying semantics
  argument, but a separate guard/terminator per existing function in this file — left for a future
  plan to keep this one's diff small and reviewable.
- `List.foldr` reaching through a conversion. Not spiked; `List.foldr` fusion itself was rejected
  for the plain-list case ([[list-foldr-fusion-spike]], stack-safety concerns) and never shipped, so
  there is no existing `List.foldr` guard for this plan to extend in the first place.
- Any conversion chain not ending in `List.foldl` (e.g. a bare `Dict.toList d |> List.map f`, no
  terminator) — the existing bare-producer-chain fusion ([[bare-producer-chain-fusion-spike]])
  already handles bare `List.map`/`filter` chains with no fold at the end, but does not know about
  these five conversions as a base either; extending it is also left for a future plan.

## Verification plan (executed; results below)

1. Build the fork compiler with this change (Docker recipe, `CLAUDE.md`).
2. Compile a `Bench.elm` fixture covering all five conversions, plus a chain with `List.map`/
   `List.filter` stages in between, at `--optimize`; confirm the generated JS shows a single
   `Dict.foldl`/`Set.foldl`/`Array.foldl`-shaped call per case with zero references to
   `Dict.toList`/`Dict.keys`/`Dict.values`/`Set.toList`/`Array.toList` in the fused function's body.
3. Order-sensitive correctness check (not a plain sum — see Motivation) between old and new binaries
   across sizes including `n = 0, 1, 2` edge cases.
4. Interleaved timing, two separate scratch directories (per the `elm-stuff` cache-contamination
   finding — never reuse one project dir across a binary swap).

**Results:** structural check passed on the first pass (steps 1-3), confirming the fusion fires and
produces correct output. Step 4's timing check, run against the *first* version of the fix (before
the `Opt.Let` hoist above), found 4 of 6 patterns 1.3x-1.4x **slower**, not faster — the spike's
1.16x-3.4x estimate never accounted for the `F2`/`A2` codegen overhead the "Post-ship fix" section
describes, since the spike measured a hand-patched simulation, not real compiler-generated call
sites. After the fix, re-running the identical steps 1-4 against a fresh binary confirmed all 6
patterns now show genuine speedups: 1.5x-2.55x (see "Post-ship fix" above for the exact per-pattern
numbers).
