# Design Spec: List Pipeline Fusion V2 (`sum`/`length`/`product` terminators, `filterMap` producer)

## Motivation

Direct follow-up to `docs/superpowers/specs/2026-07-18-list-foldl-map-filter-fusion-design.md` (V1,
merged `6dac555d`), which fused `List.map`/`List.filter` producer chains into a `List.foldl`
terminator only, and explicitly deferred `List.sum`/`List.length`/`List.product` as terminators and
`List.filterMap` as a producer to "Future work" (that doc's closing section).

Nutzen-check spike (session scratch `fusion-v2-spike`, 2026-07-19): a 5-function `Bench.elm`
(`sumPipeline2..4`, `fmPipeline2..3`) compiled `--optimize` with the current fork compiler (main
`6dac555d`). Confirmed in the generated JS that `List.sum`/`List.filterMap` are themselves
`elm/core`-library functions implemented via `List.foldl`/`List.foldr` over an already-built list
(`elm/core:List.elm`: `sum numbers = foldl (+) 0 numbers`, `product numbers = foldl (*) 1 numbers`,
`length xs = foldl (\_ i -> i + 1) 0 xs`, `filterMap f xs = foldr (maybeCons f) [] xs`) — so every
`filter`/`map` stage feeding one of these, plus the terminator itself, is a *separate* full
traversal+allocation, exactly the shape V1 already fuses for `foldl`.

Hand-fused single-pass equivalents (same extracted closures, same list, one `while (list.b)` loop
walking `.a`/`.b`, mirroring the kernel's own `foldl` loop) benchmarked interleaved against the real
compiled baseline (N=1,000 to 200,000, 9 interleaved blocks × 30 calls/block, median, 2 independent
process runs, checksums identical throughout):

| pipeline | speedup (both runs, all N) |
|---|---|
| `filter → sum` | 6.1x – 15.1x |
| `filter → map → sum` | 11.7x – 39.9x |
| `filter → map → filter → sum` | 22.0x – 29.4x |
| `filterMap → foldl` | 3.7x – 6.6x |
| `filterMap → map → foldl` | 3.9x – 6.9x |

`sum`/`product`/`length`-terminated pipelines fuse *even better* than V1's `foldl`-terminated ones
(8x-16x): fusing away `sum`'s own `foldl` traversal over a list `filter`/`map` built via their own
`foldr`/`foldl` compounds on top of the intermediate-list elimination V1 already does.
`filterMap`-producer pipelines land in a smaller but still clearly positive range (3.6x-7x, closer to
V1's own numbers) — plausible since `maybeCons`/`Maybe` pattern dispatch carries more per-element
base cost than a plain predicate/transform call, so the traversal savings are a smaller fraction of
total work. Full derivation: `[[list-fusion-v2-spike]]` memory entry.

## Scope (V2)

Two independent extensions to the existing V1 machinery in `Optimize/Expression.hs`, both additive
(no change to V1's existing `foldl`/`map`/`filter` behavior):

**A. New terminal consumers:** `List.sum`, `List.length`, `List.product`, in addition to the existing
`List.foldl`. Each is a fixed step+init pair over the same underlying `List.foldl` kernel loop shape:
- `sum`: step = `Basics.add`, init = `0`
- `product`: step = `Basics.mul`, init = `1`
- `length`: step = `\_ acc -> acc + 1` (ignores the element), init = `0`

**B. New producer stage:** `List.filterMap`, alongside the existing `List.map`/`List.filter`, in any
order/position within a chain. Unlike `map`/`filter` (whose function/predicate result plugs directly
into an `Opt.Call`/`Opt.If`), `filterMap`'s function returns `Maybe b` — fusing it needs a genuine
`Just`/`Nothing` pattern match, not a plain `If`. See "Mechanism" below for how this reuses the
existing decision-tree compiler instead of hand-rolling a ctor-tag test.

**Still explicitly out of scope (unchanged from V1, plus one addition):**
- `List.foldr` as a terminator (different traversal direction/associativity — a *different* kernel
  loop shape than `foldl`, not just a different step/init pair; deferred, not spiked).
- `List.sortBy`/`sortWith`, `List.take`/`drop`, `List.concatMap`, `List.map2..5`, `List.reverse`,
  `List.append`, `List.indexedMap` as producers (same reasons as V1's design doc: need whole-list
  materialization, extra count state, one-to-many mapping, or multiple source lists).
- Bare producer-chain fusion with no terminal consumer (`List.map f (List.map g xs)` used directly).
- The known **double-evaluation of a mapped value across a following filter** (V1's documented
  limitation: `wrapStage`'s `StageFilter` case uses `elemExpr` twice). `StageFilterMap` inherits the
  *same* limitation when it follows a `StageMap` (the mapped value is recomputed once per downstream
  `StageFilter`/`StageFilterMap`) — not a new bug class, not fixed here, same `Opt.Let`-memoization
  follow-up noted in V1's design doc applies to both.

None of the "out of scope" cases are touched: `peelListStage` simply returns `Nothing` (for producers)
or the trigger guards simply don't match (for terminators) the moment an unrecognized shape is hit, so
an out-of-scope combinator anywhere in a chain never produces wrong output, only a missed (safe)
fusion opportunity — identical safety argument to V1.

## Why this is semantics-preserving

Same argument as V1 (see that design doc's "Why this is semantics-preserving" section) applies
unchanged to extension A: `sum`/`length`/`product` are simply alternate (step, init) pairs feeding
the *same* `buildFusedFold` construction V1 already proves correct — no new evaluation-order
reasoning needed, since the synthesized result is *literally* a `List.foldl` call, same as V1's.

For extension B (`filterMap`): the synthesized `Just`/`Nothing` dispatch is built by handing genuine
`Can.Pattern` values to `Optimize.Case.optimize`/`Optimize.DecisionTree.compile` — the *same* compiler
machinery a hand-written `case f x of Just y -> ...; Nothing -> ...` in ordinary user code goes
through (see `Optimize.Expression.hs`'s existing `Can.Case` handling, lines 193-208, which this reuses
via `destructCase`/`Case.optimize`, not a parallel reimplementation). This means:
- Dev vs. Prod constructor-tag representation (string tag `'Just'`/`'Nothing'` in Dev, numeric `$: 0`/
  `$: 1` in Prod) is handled correctly for free, by the same code path that already handles every
  other `Maybe` pattern match in every Elm program — no new mode-specific logic to get wrong.
- `f`'s call site is inside the synthesized `Opt.Let`-bound `temp`, called exactly once per element —
  same "each sub-expression evaluated exactly once" argument V1 makes for `map`/`filter`'s
  function/predicate.
- Exhaustiveness is trivially satisfied: the two supplied patterns (`Just y`, `Nothing`) cover
  `Maybe`'s full 2-constructor union (`_u_numAlts = 2`), so `DecisionTree.compile` never needs a
  fallback/incomplete-match case.

The `Can.Union`/`Can.Ctor`/`Can.PatternCtorArg` values fed to the synthesized `Just`/`Nothing`
patterns need a `Type` field in a few places (`PatternCtorArg`'s cached type, `Ctor`'s cached arg
types) that are **only used pre-Optimize, for type inference** (confirmed by reading
`destructCtorArg`, which discards `PatternCtorArg`'s type field with `_`, and `DecisionTree.testAtPath`,
which discards `Can.Union`'s `_u_vars` with `_`) — safe to fill with an inert placeholder
(`Can.TVar "a"`) since nothing past canonicalization reads them.

## Where this lives

Same file, same integration point as V1: `Optimize.Expression.hs`, inside `optimize`'s
`case expression of`. No new `AST.Optimized` constructor for extension A (the synthesized result is
an ordinary `Opt.Call` to `List.foldl`, exactly like V1). Extension B **does** use an existing
`AST.Optimized` constructor already in the format — `Opt.Case Name Name (Decider Choice) [(Int, Expr)]`
— but doesn't add a new one: `.elmo`/binary format is unchanged either way.

**Mode:** uniform Dev + Prod, same as V1 (a pure `Can`→`Opt` rewrite, not conditioned on any
`Mode.Prod`-only whole-program table).

## Mechanism

### Extension A: `sum`/`length`/`product` terminators

Factor V1's foldl-call-construction tail (the `do` block building `composed`/`xName`/`accName`/`body`
and the final `Opt.Call optFoldl [...]`) into a shared helper, parameterized over the base step
continuation and the fold's initial value, so all four terminators (`foldl`, `sum`, `product`,
`length`) share one construction path:

```haskell
-- Shared tail of every fusion trigger below: given a base step continuation
-- and an initial accumulator value already as Opt.Expr, peels/composes
-- `stages` over `source` and emits one ordinary List.foldl call. `initExpr`
-- is a plain Opt.Expr (Opt.Int 0/1 for sum/length/product's implicit init,
-- or the user's own already-`optimize`'d acc argument for foldl).
buildFusedFold :: Hints -> Cycle -> StepK -> Opt.Expr -> [ListStage] -> Can.Expr -> Names.Tracker Opt.Expr
buildFusedFold hints cycle base initExpr stages source =
  do  optSource <- optimize hints cycle source
      composed  <- foldM (wrapStage hints cycle) base stages
      xName     <- Names.generate
      accName   <- Names.generate
      body      <- composed (Opt.VarLocal xName) (Opt.VarLocal accName)
      optFoldl  <- Names.registerGlobal ModuleName.list "foldl"
      pure $ Opt.Call optFoldl
        [ Opt.Function [xName, accName] body
        , initExpr
        , optSource
        ]


-- `length`'s implicit step ignores the element entirely (`\_ i -> i + 1`),
-- unlike `baseStepK` which calls a real user-supplied 2-arg step function —
-- needs its own base continuation rather than reusing baseStepK with a
-- synthesized lambda.
baseStepKLength :: Opt.Expr -> StepK
baseStepKLength optAdd _ accExpr =
  pure (Opt.Call optAdd [accExpr, Opt.Int 1])
```

Four wildcard-guarded alternatives (replacing V1's single `foldl`-only one), each reusing
`collectApplication`/`peelChain` exactly as V1 does, differing only in argument count (`foldl` takes
3 args, the other three take 1) and which step/init `buildFusedFold` is called with:

```haskell
_
  | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
  , home == ModuleName.list, name == "foldl"
  , [stepArg, accArg, listArg] <- args
  , (stages@(_:_), source) <- peelChain listArg
  ->
      do  optStep <- optimize hints cycle stepArg
          optAcc  <- optimize hints cycle accArg
          buildFusedFold hints cycle (baseStepK optStep) optAcc stages source

  | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
  , home == ModuleName.list, name == "sum"
  , [listArg] <- args
  , (stages@(_:_), source) <- peelChain listArg
  ->
      do  optAdd <- Names.registerGlobal ModuleName.basics "add"
          buildFusedFold hints cycle (baseStepK optAdd) (Opt.Int 0) stages source

  | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
  , home == ModuleName.list, name == "product"
  , [listArg] <- args
  , (stages@(_:_), source) <- peelChain listArg
  ->
      do  optMul <- Names.registerGlobal ModuleName.basics "mul"
          buildFusedFold hints cycle (baseStepK optMul) (Opt.Int 1) stages source

  | (A.At _ (Can.VarForeign home name _), args) <- collectApplication (A.At region expression)
  , home == ModuleName.list, name == "length"
  , [listArg] <- args
  , (stages@(_:_), source) <- peelChain listArg
  ->
      do  optAdd <- Names.registerGlobal ModuleName.basics "add"
          buildFusedFold hints cycle (baseStepKLength optAdd) (Opt.Int 0) stages source
```

(`"add"`/`"mul"`/`"foldl"`/`"sum"`/`"product"`/`"length"` are `Name.Name` string literals via this
file's existing `OverloadedStrings` pragma — same style as the existing `name == "foldl"` guard.)

### Extension B: `filterMap` producer

New `ListStage` constructor, peeled exactly like `map`/`filter` (via `collectApplication`, so `|>`
chains work identically):

```haskell
data ListStage
  = StageMap Can.Expr Can.Expr
  | StageFilter Can.Expr Can.Expr
  | StageFilterMap Can.Expr Can.Expr   -- f, inner list expr


peelListStage :: Can.Expr -> Maybe ListStage
peelListStage expr =
  case collectApplication expr of
    (A.At _ (Can.VarForeign home name _), [f, inner])
      | home == ModuleName.list, name == "map"       -> Just (StageMap f inner)
      | home == ModuleName.list, name == "filter"     -> Just (StageFilter f inner)
      | home == ModuleName.list, name == "filterMap"  -> Just (StageFilterMap f inner)
    _ ->
      Nothing


stageInner :: ListStage -> Can.Expr
stageInner (StageMap _ inner)       = inner
stageInner (StageFilter _ inner)    = inner
stageInner (StageFilterMap _ inner) = inner
```

Synthesized `Maybe` union/pattern info — a fixed, compiler-known shape (not looked up from any
module's interface, since `Maybe` is always `elm/core`'s `Maybe`):

```haskell
-- Synthesized Maybe union info + Just/Nothing patterns, used to fuse
-- filterMap's Maybe-producing function via the existing pattern-match
-- compiler (Optimize.Case/Optimize.DecisionTree) instead of hand-rolling a
-- ctor-tag test whose Dev/Prod representation this pass would otherwise
-- have to track itself. The `Can.TVar "a"` type placeholders are inert —
-- see "Why this is semantics-preserving" above for why nothing past
-- canonicalization reads them.
maybeUnion :: Can.Union
maybeUnion =
  Can.Union ["a"]
    [ Can.Ctor "Just" Index.first 1 [Can.TVar "a"]
    , Can.Ctor "Nothing" Index.second 0 []
    ]
    2
    Can.Normal


pJust :: Name.Name -> Can.Pattern
pJust argName =
  A.At A.zero $ Can.PCtor
    ModuleName.maybe
    Name.maybe
    maybeUnion
    "Just"
    Index.first
    [Can.PatternCtorArg Index.first (Can.TVar "a") (A.At A.zero (Can.PVar argName))]


pNothing :: Can.Pattern
pNothing =
  A.At A.zero $ Can.PCtor
    ModuleName.maybe
    Name.maybe
    maybeUnion
    "Nothing"
    Index.second
    []
```

`wrapStage`'s new case, following the exact same recipe `Optimize.Expression.hs`'s existing
`Can.Case` handling uses (bind the scrutinee via `Opt.Let` since it's not a bare `Opt.VarLocal`, get
field destructors via `destructCase`, call `Optimize.Case.optimize` — a **pure** function, not
`Names.Tracker`-monadic, unlike everything else in this pass):

```haskell
    StageFilterMap f _ ->
      do  optF <- optimize hints cycle f
          pure $ \elemExpr accExpr ->
            do  temp        <- Names.generate
                yName       <- Names.generate
                justDs      <- destructCase temp (pJust yName)
                thenBranch0 <- inner (Opt.VarLocal yName) accExpr
                let thenBranch = foldr Opt.Destruct thenBranch0 justDs
                pure $ Opt.Let (Opt.Def temp (Opt.Call optF [elemExpr]))
                  (Case.optimize temp temp
                    [ (pJust yName, thenBranch)
                    , (pNothing, accExpr)
                    ])
```

`destructCase temp (pJust yName)` resolves (by hand-tracing `destructHelp`'s `PCtor`/single-arg/
`Can.Normal` branch) to exactly one destructor: extract field index 0 (`.a`) of `temp` into `yName` —
the ordinary "unwrap a 1-field `Normal`-opts constructor" path every `Just`-pattern in any Elm program
already goes through. `destructCase temp pNothing` resolves to `[]` (no bindings) since `Nothing` has
zero constructor arguments.

`Case.optimize`'s import (`qualified Optimize.Case as Case`) and every other name used above
(`Index.first`/`second`, `A.zero`/`A.At`, `ModuleName.maybe`, `Name.maybe`) are already imported by
this file — verified by reading its import list; no new imports needed for either extension.

## Verification protocol

Same overall shape as V1's plan (before/after binary comparison, structural grep, checksum sweep,
Dev-mode check, interleaved timing) — see that plan's Task 2 for the full recipe this reuses
(worktree-based "before" binary, `elm-stuff` cache gotcha, scope-injection exposure technique).
V2-specific additions:

1. **Structural check, extension A:** grep a fused `sum`/`product`/`length`-terminated pipeline's
   function body for zero `List.map`/`List.filter` calls and exactly one `List.foldl` call (same
   check V1 already runs for `foldl`-terminated pipelines, just re-pointed at the new terminators).
2. **Structural check, extension B:** grep a fused `filterMap`-containing pipeline's function body for
   zero `List.filterMap` calls, and confirm the body contains a `.$` tag test (proof the Maybe match
   compiled to a real ctor-tag dispatch, not something that silently no-op'd).
3. **Correctness, both extensions:** checksum sweep across list sizes `0, 1, 2, 3, 10, 137, 10000` for
   at least one pipeline per new terminator/producer, plus:
   - an all-`Nothing` case for `filterMap` (predicate-equivalent to V1's all-filtered-out case),
   - an all-`Just` case for `filterMap`,
   - a negative-alias control (`mySum = List.sum`, called via alias) proving the scope limit doesn't
     silently break code, matching V1's `myFoldl` control.
4. **Dev-mode correctness for extension B specifically:** this is the one place V2 exercises Dev-mode
   `Maybe` tag representation (string `'Just'`/`'Nothing'`) through freshly-synthesized patterns for
   the first time in this pass — compile without `--optimize` and confirm checksums still match, not
   just that the build succeeds silently.
5. **Interleaved timing:** re-run the spike's harness shape against the real compiler's output for
   both extensions, confirm speedups land in the ballpark the spike found (sum: 6x-40x growing with
   stage count; filterMap: 3.6x-7x) — upgrading the spike's hand-patch *ceiling* estimate into a real,
   compiler-produced measurement, same as V1's Task 2 Step 8.

## Future work (not V2)

- `List.foldr` as an additional terminator (different kernel loop shape, needs its own
  `buildFusedFold`-analog, not spiked).
- `Opt.Let`-memoization of a mapped value that's consumed by more than one downstream
  `StageFilter`/`StageFilterMap` (the double-evaluation limitation inherited from V1, now shared by
  two stage kinds instead of one).
- `List.sortBy`/`take`/`drop`/`concatMap`/`map2..5` as fusion barriers with their own attach points.
- Bare producer-chain fusion with no terminal consumer.
