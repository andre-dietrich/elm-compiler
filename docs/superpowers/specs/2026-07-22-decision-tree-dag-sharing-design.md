# Decision-Tree DAG Sharing — Design Spec

**Date:** 2026-07-22 (revised same day — see Revision note)
**Status:** Approved for planning

## Revision note

The first version of this spec proposed detecting duplicate `Opt.Decider Int` subtrees via
structural equality (`Eq`/`Ord`) and packaging each duplicate as its own nested `Opt.Case`. While
writing the implementation plan, working out the exact comparison logic showed that approach can
**never** find a real duplicate: every original case-arm gets a unique target index via `indexify`
(0, 1, 2, ...), so two genuinely-duplicate branches — e.g. `(Pending, Low) -> "wait"` and
`(Active, Low) -> "wait"` — compile to `Leaf 0` and `Leaf 3` respectively. Different integers are
never `Eq`-equal regardless of how identical the surrounding test structure or the actual leaf body
is. That design would have compiled and run, but silently never fired.

A second version proposed doing the merge in `Optimize/Expression.hs`, before branches reach
`Case.optimize`, comparing pre-optimization `Can.Expr` bodies. Deriving the exact mechanics further
showed the merge decision has to be made at the point target indices are actually assigned — which
happens *inside* `Optimize.Case.optimize`'s `indexify` step, not in its caller — since
`Case.optimize`'s existing signature (`[(Can.Pattern, Opt.Expr)] -> Opt.Expr`) assigns one fresh
target per list position unconditionally, regardless of what the caller passes in. This final
version does the merge exactly there: replacing `indexify`'s blind enumeration with target
assignment that reuses an earlier index when a later branch qualifies for merging. This is smaller
than either earlier version — one function inside one file, no signature or call-site changes
anywhere — and reuses the existing `countTargets`/`createChoices`/`Opt.Jump` machinery completely
unmodified.

## Background

The [[decision-tree-dag-sharing-spike]] (2026-07-21, memory) hand-patch-benchmarked a JS-level
simulation of this optimization and found a robust 1.40x-1.46x speedup, flat across four orders of
magnitude of input size, with a control run ruling out dead-code elimination as the source of the
gain. This spec turns that finding into a real compiler change ("Mechanism A" from that spike;
"Mechanism B", cold-branch outlining, was found conditional/regressive under uniform call-site
traffic and is explicitly out of scope here).

**Root cause in the current compiler:** `Optimize.Case.optimize`'s `indexify` step assigns every
case-arm its own unique target index before decision-tree compilation ever runs, even when two or
more arms produce an identical result.
`Optimize.Case.treeToDecider` then builds each sibling edge of the decision tree independently
(`map (second treeToDecider) edges`) — so when a case expression's decision tree contains sibling
branches whose bodies are genuinely identical, for example
`case (status, priority) of (Pending, Low) -> "wait"; (Active, Low) -> "wait"; ...`, the compiler
allocates two distinct target indices and, absent any correction, never notices the bodies match.
The **existing** sharing mechanism (`Optimize.Case.countTargets`/`createChoices`/`Opt.Jump`) only
dedupes leaves that already share the same target index — it does nothing to discover that two
*different* indices happen to lead to equal code.

## Goal

Detect case-arms whose bodies are structurally identical and whose patterns bind no variables (see
Correctness invariant below), and assign them the **same** target index before decision-tree
compilation runs — letting the existing, unmodified `countTargets`/`createChoices`/`Opt.Jump`
mechanism do the actual sharing, exactly the way it already shares any target reached by 2+ leaves
today.

## Non-goals

- Sharing bodies that reference pattern-bound variables (`PVar`/`PAlias` anywhere in the arm's own
  pattern). See Correctness invariant.
- General cross-expression CSE (sharing across textually-separate `case`-of-`case` expressions in
  different outer arms). Only arms of the *same* `case` are considered.
- Cold-branch outlining (spike Mechanism B) — conditional/regressive, not part of this plan.
- Any whole-program or `Mode`-dependent analysis. This transformation runs identically for
  `Mode.Dev` and `Mode.Prod`, since it happens in `Optimize.Case`, before `Generate.Mode` ever
  sees the tree.
- Deriving `Eq`/`Ord` on `Can.Expr`/`Opt.Expr` generally. A narrow, hand-written, conservative
  comparison is used instead (see Architecture).

## Architecture

The transformation lives entirely inside `compiler/src/Optimize/Case.hs`'s `optimize` function,
replacing its `indexify` target-assignment step. No changes to `Optimize/Expression.hs` (no call
sites change — `Case.optimize`'s external type signature is unchanged) and no changes to
`AST.Optimized`'s types.

Today, `optimize`'s first step is:

```haskell
(patterns, indexedBranches) = unzip (zipWith indexify [0..] optBranches)
```

which gives every entry of `optBranches :: [(Can.Pattern, Opt.Expr)]` its own fresh target index,
unconditionally, one per list position. This is replaced by `assignTargets`, a left fold over
`optBranches` that reuses an earlier index instead of minting a fresh one when the current branch
qualifies for merging:

1. A branch qualifies for merging only if its own pattern binds no variable
   (`bindsNoVariables :: Can.Pattern -> Bool`, recursing over `Pattern_`; `False` — i.e. "does
   bind" — for any `PVar`/`PAlias`/`PRecord`, `True` for everything else, including nested patterns
   built purely from literals/wildcards/constructors/tuples).
2. Among qualifying branches, it is merged into (assigned the same target as) the *first* earlier
   qualifying branch whose already-optimized body is `sameExpr`-equal (see below). Non-qualifying
   (variable-binding) branches always get a fresh target, exactly as today, and are never used as a
   merge source or target for anything else — this is what makes the merge unconditionally safe
   (see Correctness invariant).
3. `patterns :: [(Can.Pattern, Int)]` keeps one entry per *original* branch (every source pattern
   still needs its own decision-tree test position, merged or not) — only the `Int` may repeat.
   `indexedBranches :: [(Int, Opt.Expr)]` keeps exactly one entry per *distinct* target — this is
   what `createChoices`/the final jump list are built from, so a merged target must not appear
   twice there.
4. The rest of `optimize` (`treeToDecider`, `countTargets`, `createChoices`, `insertChoices`) runs
   completely unchanged, on these same two lists, exactly as it does today. Because two-or-more
   original branches now point at the same target index, `countTargets` naturally counts it as
   reached multiple times, and `createChoices` naturally emits `Opt.Jump` instead of `Opt.Inline`
   for it — the exact mechanism that already exists today for any other multiply-reached target.

### `sameExpr` — conservative structural equality

`sameExpr :: Opt.Expr -> Opt.Expr -> Bool` is a hand-written recursive comparison over `Opt.Expr`
(not a derived `Eq` instance — deriving one for the whole optimized AST is out of scope, see
Non-goals). It compares the *already-optimized* body, which both avoids re-deriving name-resolution
from scratch and sidesteps a subtlety: any body that would need `Optimize.Names.generate` to mint a
fresh local name during optimization (i.e. anything building a `Let`/`Destruct`/`Case`/`Function`)
is already outside the whitelist below, so nothing being compared can differ merely due to
otherwise-harmless alpha-renaming.

`sameExpr` positively supports exactly the constructors that can appear in a variable-free body
without introducing new bindings: `Bool`, `Chr`, `Str`, `Int`, `Float`, `Unit` (direct value
comparison); `VarLocal`, `VarGlobal`, `VarEnum`, `VarBox`, `VarKernel` (compared by
name/global-identity fields only — safe, since a variable-free body's `VarLocal` can only refer to
an outer-scope binding, identical in every arm of the same `case`); `List`, `Call`, `If`, `Tuple`
(recurse structurally into sub-expressions); `Accessor`/`Access` (field name comparison).

Every other constructor (`VarCycle`, `VarDebug`, `Function`, `TailCall`, `TailCallCons`,
`TailCallConsBase`, `Let`, `Destruct`, `Case`, `Update`, `Record`, `Shader`, `PrimOp`) makes
`sameExpr` return `False` unconditionally for that pair, even if both sides happen to use the same
one — these forms either introduce their own bindings (subtler aliasing questions, deliberately
deferred) or aren't worth the risk for a first version (`PrimOp` is excluded specifically to avoid
needing an `Eq` instance on `AST.Optimized.PrimBinop`, keeping this change from touching
`AST.Optimized` at all). Returning `False` only ever *misses* a sharing opportunity; it can never
cause an incorrect merge, so this restriction is free to make generously.

## Correctness invariant

**A body may only be merged with another if neither arm's own pattern binds any variable.** If it
did, the same variable name in two different arms' patterns could be extracted via a different path
relative to the case's scrutinee (e.g. `(Pending, Loud x) -> ...` vs `(Active, VeryLoud x) ->
...` — same name `x`, different sub-position), and merging their target indices would run the wrong
extraction against the wrong branch's compiled destructuring. Restricting to patterns that bind
nothing at all sidesteps this: a variable-free body's meaning cannot depend on *which* arm's pattern
matched, only on outer-scope bindings that are identical no matter which arm fired, so merging two
such equal bodies is unconditionally sound.

This is the one place a bug would be easy to introduce, so the plan's manual test fixtures must
include a branch that binds a variable and has a body that's textually identical to another arm's
(to confirm it is correctly *not* merged), alongside the positive case.

## Components touched

- `compiler/src/Optimize/Case.hs` — new `assignTargets`/`bindsNoVariables`/`argPattern`/`sameExpr`
  (+small helpers) functions; `optimize`'s `indexify` step is replaced by `assignTargets`. New
  import: `qualified Reporting.Annotation as A` (for pattern-matching `Can.Pattern`'s `A.At`
  wrapper) and `Data.List (foldl')`.
- `compiler/src/Optimize/Expression.hs` — **no changes**. `Case.optimize`'s external signature is
  unchanged, so none of its ~4 call sites need touching.
- `compiler/src/AST/Optimized.hs` — **no changes**.
- `compiler/src/Generate/JavaScript/Expression.hs` — **no changes**.

## Testing strategy

No automated test suite exists in this repository (see `CLAUDE.md`). Verification is manual,
following the project's established pattern:

1. Build the compiler via the Docker toolchain (`CLAUDE.md` build recipe).
2. Hand-written scratch `.elm` fixtures (outside the repo, in the session scratchpad), covering:
   - The motivating case: a tuple/multi-argument match with variable-free arms whose bodies repeat
     verbatim across multiple outer values (the `(status, priority)` shape from the earlier
     discussion).
   - The correctness-invariant edge case: two arms with textually-identical bodies where at least
     one arm's pattern binds a variable — must confirm these are **not** merged.
   - A case with **no** duplication, as a regression check — generated JS must be unchanged versus
     the pre-change compiler.
3. Execute all fixtures under Node to confirm runtime behavior is correct.
4. Diff/inspect generated JS for both plain `elm make` (Dev) and `elm make --optimize` (Prod)
   output — confirm the merged targets show up as a single shared `Opt.Jump`/labeled block instead
   of duplicated inline code.
5. Re-run the original spike's interleaved-process benchmark harness against the **real** compiler
   output (not hand-patched JS) for the motivating case, to confirm the 1.40x-1.46x finding holds
   end-to-end.

## Risks

- **Correctness invariant above** — the main real risk, mitigated by a dedicated test fixture and by
  keeping the merge condition maximally conservative (variable-free patterns only).
- **`sameExpr` scope creep** — temptation to add more constructors later; each addition needs the
  same soundness argument. Deliberately narrow for v1.
- **No format/`.elmo` risk** — this design touches no `AST.Optimized`/`AST.Canonical` type
  definitions at all, only adds ordinary functions in `Optimize/Case.hs`.

## Addendum (found during implementation): dead destructor blocks the motivating case

Task 1 built exactly as designed and passed its own build gate, but manual fixture testing (plan
Task 2) found the merge does not fire for the plan's own motivating example —
`case (status, priority) of (Pending, Low) -> "wait"; (Active, Low) -> "wait"; ...` — even though
both arms' patterns bind no variable and both bodies are the literal string `"wait"`.

**Root cause, in a function this design did not originally touch:**
`Optimize.Expression.destructHelp`'s `Can.PCtor` case, for a **nullary** constructor pattern
(`args = []`, e.g. `Pending`) whose path is *not* `Opt.Root` (i.e. it's nested inside a tuple/list/
other compound pattern rather than being the case's direct scrutinee), unconditionally allocates a
fresh-named `Opt.Destructor` before folding over `args`:

```haskell
_ ->
  do  name <- Names.generate
      foldM (destructCtorArg (Opt.Root name)) (Opt.Destructor name path : revDs) args
```

Since `args` is empty, the `foldM` is a no-op and `name` is never referenced by anything — this
destructor exists purely as dead codegen (an unused local binding), independent of this feature
entirely. But its presence wraps every arm's optimized body in `Opt.Destruct` with a distinct fresh
name per arm, and `sameExpr` (by design) treats `Opt.Destruct` as always non-equal — so the merge
never triggers for any constructor pattern nested inside something else, which is precisely the
shape of the plan's own motivating multi-value-dispatch example, and a very common real Elm idiom.

Manual testing confirmed the mechanism *does* work correctly for: single-column `Int`/`Bool`/
custom-type `case` (patterns directly at `Opt.Root`), and `Bool` patterns at any nesting depth
(`destructHelp`'s `PBool` case never allocates a destructor, regardless of path). It fails
specifically for a non-nullary-free constructor pattern nested inside a tuple/list/etc.

**Fix (root cause, not a `sameExpr` workaround):** `destructHelp`'s `Can.PCtor` case gets a new
first branch for `args = []`, returning `pure revDs` unconditionally — matching what already
happens today when such a pattern sits at `Opt.Root`. This never allocates a destructor for a
nullary constructor regardless of path, since there is provably nothing to destructure:

```haskell
    Can.PCtor _ _ (Can.Union _ _ _ opts) _ _ args ->
      case args of
        [] ->
          pure revDs

        [Can.PatternCtorArg _ _ arg] ->
          case opts of
            Can.Normal -> destructHelp (Opt.Index Index.first path) arg revDs
            Can.Unbox  -> destructHelp (Opt.Unbox path) arg revDs
            Can.Enum   -> destructHelp (Opt.Index Index.first path) arg revDs

        _ ->
          case path of
            Opt.Root _ ->
              foldM (destructCtorArg path) revDs args

            _ ->
              do  name <- Names.generate
                  foldM (destructCtorArg (Opt.Root name)) (Opt.Destructor name path : revDs) args
```

This is independently justified as removing genuinely dead codegen (an always-unused variable
binding), not merely a workaround for this feature — and, as a side effect, it recovers sharing for
the nested-constructor-pattern case, which is the shape this whole feature was motivated by.

**Components touched (revised):** `compiler/src/Optimize/Expression.hs` is now also touched by this
plan — specifically `destructHelp`'s `Can.PCtor` case (around what was originally lines 588-603).
This is a small, self-contained, behavior-preserving change (it only removes an unreachable/unused
binding) and does not change `Optimize.Case.hs` further or affect the `.elmo` binary format.
