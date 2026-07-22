# Design Spec: `Set.foldl` / `filter` Pipeline Fusion

## Motivation

Follow-up to [[dict-map-filter-fusion-spike]] (`924428fc`, merged same day): once that change
shipped, a direct check against the real compiled output showed `Set` does **not** benefit, even
though `type Set a = Set_elm_builtin (Dict a ())` is a `Can.Unbox` type and erases to a bare `Dict`
value at runtime (`$elm$core$Set$Set_elm_builtin = $elm$core$Basics$identity`, confirmed in
generated JS). `Set.filter`/`Set.foldl` are themselves thin wrappers that call straight into
`Dict.filter$unwrapped`/`Dict.foldl$unwrapped` — but the new `peelDictStage` matcher in
`Optimize/Expression.hs` only recognizes calls whose `home == ModuleName.dict`, so
`s |> Set.filter p |> Set.foldl f acc` falls straight through unfused: `Set.filter` still goes
through `Dict`'s full `O(n log n)` insert-and-rebalance rebuild before a separate `Set.foldl`
traversal.

Memory: `set-filter-foldl-fusion-spike.md` (hand-patched, 8.68x-13.31x) and its "Update" section
(real-compiler A/B: a genuinely fused 3-stage `Dict` chain ran 1.83x-2.77x *faster* than an unfused
2-stage `Set` chain doing strictly less work).

## Mechanism

Same shape as the Dict fusion, but simpler: `Set` has no safe analogue of `Dict.map`.
`elm/core`'s `Set.map` is `fromList (foldl (\x xs -> func x :: xs) [] set)` — it can change key
*order* (the mapped function isn't order-preserving in general), so a full rebuild is not
avoidable there the way `Dict.map` (which never touches keys) is. Only `Set.filter -> Set.foldl`
is fused here; `Set.map` is explicitly out of scope (would need a different, more expensive
argument about sortedness this plan does not make).

New, parallel definitions in `Optimize/Expression.hs` (own section, not folded into `DictStage`,
same reasoning the Dict section itself gives for not folding into `ListStage`/`StepK`: different
step-function arity — `Set.foldl`'s step is `comparable -> b -> b`, two arguments, no separate
key/value split):

- `SetStage = SStageFilter Can.Expr Can.Expr` (predicate, inner set expr) — one constructor,
  since filter is the only fusable producer.
- `peelSetStage` / `peelSetChain` — mirrors `peelDictStage`/`peelDictChain`, matches
  `home == ModuleName.set, name == "filter"` only. A chain of multiple `Set.filter`s (`s |>
  Set.filter p1 |> Set.filter p2 |> Set.foldl f acc`) still peels correctly — nothing here assumes
  exactly one stage.
- `SetStepK = Opt.Expr -> Opt.Expr -> Names.Tracker Opt.Expr` (`elemExpr -> accExpr -> result`),
  two arguments (element doubles as key — there is no separate value slot, unlike `DictStepK`'s
  three).
- `baseSetStepK` / `wrapSetStage` / `buildFusedSetFold` — same structure as the Dict counterparts,
  narrowed to two-argument step closures. The synthesized fold registers `Set.foldl` itself (not
  `Dict.foldl` directly) as the terminator, keeping the change local to what a user's `Set.foldl`
  call already resolves to — consistent with how the Dict fusion keeps calling `Dict.foldl` rather
  than reaching for kernel internals.
- Trigger clause added immediately after the existing `ModuleName.dict, name == "foldl"` clause in
  `optimize`'s guard chain: `home == ModuleName.set, name == "foldl"`, args
  `[stepArg, accArg, setArg]` (matches `Set.foldl`'s real 3-arg signature), peels via
  `peelSetChain`.

## Correctness argument

Identical to the Dict case, restricted to filter: `Set.foldl` walks the underlying tree in-order
by key (same `Dict.foldl$unwrapped` recursion, since `Set.foldl$unwrapped` delegates to it
directly) regardless of how the tree was built — the BST invariant alone guarantees this, no
insert/rebalance history matters. Fusing `filter`'s predicate check into the same walk that
`foldl` already performs, skipping accumulation for rejected keys, produces the same accumulator
value as building the filtered tree first and folding it separately, for the same reason
`wrapDictStage`'s `DStageFilter` case does (`Opt.If [(pred, thenBranch)] accExpr`, unchanged here).

## Verification plan

1. Build the fork compiler with this change (Docker recipe, `CLAUDE.md`).
2. Compile a `Bench.elm` fixture with `s |> Set.filter p |> Set.foldl f acc` at `--optimize`,
   confirm the generated JS shows a single `Set.foldl`-shaped traversal with the predicate inlined
   into the step (no intermediate `Dict.filter$unwrapped`/insert-rebuild call), same check used to
   discover the gap in the first place.
3. Benchmark old vs. new compiled output for the same source (two separate scratch directories,
   per the `elm-stuff` cache-contamination finding — never reuse one project dir across a binary
   swap), interleaved Node processes, checksum-verified, sizes 1e3-1e6.
