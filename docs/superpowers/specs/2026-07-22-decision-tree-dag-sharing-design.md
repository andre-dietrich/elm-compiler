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
is. That design would have compiled and run, but silently never fired. This revision replaces it
with a mechanism that reuses the existing target-sharing machinery instead of building a new
subtree-sharing layer next to it.

## Background

The [[decision-tree-dag-sharing-spike]] (2026-07-21, memory) hand-patch-benchmarked a JS-level
simulation of this optimization and found a robust 1.40x-1.46x speedup, flat across four orders of
magnitude of input size, with a control run ruling out dead-code elimination as the source of the
gain. This spec turns that finding into a real compiler change ("Mechanism A" from that spike;
"Mechanism B", cold-branch outlining, was found conditional/regressive under uniform call-site
traffic and is explicitly out of scope here).

**Root cause in the current compiler:** `Optimize.Expression`'s handling of `Can.Case expr branches`
(and its `optimizeTail` mirror) assigns every case-arm its own unique target index via `indexify`
before decision-tree compilation ever runs, even when two or more arms produce an identical result.
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
  `Mode.Dev` and `Mode.Prod`, since it happens in `Optimize.Expression`, before `Generate.Mode` ever
  sees the tree.
- Deriving `Eq`/`Ord` on `Can.Expr`/`Opt.Expr` generally. A narrow, hand-written, conservative
  comparison is used instead (see Architecture).

## Architecture

The transformation lives in `compiler/src/Optimize/Expression.hs`, in the `Can.Case expr branches`
handling (and its structurally-identical `optimizeTail` counterpart), *before* branches are indexed
and handed to `Optimize.Case.optimize`/`DT.compile`. No changes to `Optimize/Case.hs`'s algorithm and
no changes to `AST.Optimized`'s types — this is purely a preprocessing step over the branch list.

1. For each `Can.CaseBranch pattern body`, determine whether `pattern` binds any variable
   (`bindsNoVariables :: Can.Pattern -> Bool`, recursing over `Pattern_`, `False` — i.e. "does
   bind" — for any `PVar`/`PAlias`, `True` for everything else including nested patterns built
   purely from literals/wildcards/constructors/tuples).
2. Among branches where `bindsNoVariables pattern == True`, group by structural equality of their
   `body :: Can.Expr`, using a new hand-written, conservative `sameExpr :: Can.Expr -> Can.Expr ->
   Bool` (see below). Branches whose pattern binds a variable are never merged with anything and
   always keep their own unique target — this is what makes the merge unconditionally safe (see
   Correctness invariant).
3. Assign target indices: each equality-class of variable-free branches (size 1 or more) gets one
   shared index; every variable-binding branch gets its own index as before. This replaces the
   current unconditional `zipWith indexify [0..]`.
4. Each *distinct* body is optimized (via the existing `optimize hints cycle branch`) exactly once
   per equality class, not once per original arm — this is a side benefit (less optimizer work
   for the merged case), not the primary goal.
5. The rest of the pipeline (`Case.optimize`, `DT.compile`, `treeToDecider`, `countTargets`,
   `createChoices`) runs completely unchanged. Because two-or-more original arms now point at the
   same target index, `countTargets` naturally counts it as reached multiple times, and
   `createChoices` naturally emits `Opt.Jump` instead of `Opt.Inline` for it — the exact mechanism
   that already exists today for any other multiply-reached target.

### `sameExpr` — conservative structural equality

`sameExpr :: Can.Expr -> Can.Expr -> Bool` is a hand-written recursive comparison over
`Can.Expr_` (not a derived `Eq` instance — deriving one for the whole canonical AST is out of scope,
see Non-goals). It positively supports exactly the constructors that can appear in a variable-free
body without introducing new bindings:

- `Chr`, `Str`, `Int`, `Float`, `Unit` — direct value comparison.
- `VarLocal`, `VarTopLevel`, `VarKernel`, `VarCtor` — compared by name/identity fields only (safe:
  a variable-free body's `VarLocal` can only refer to an outer-scope binding, which is the same
  binding in every arm of the same `case`, since these branches don't bind anything themselves).
- `Call`, `Tuple`, `List`, `If`, `Access`, `Binop` — recurse structurally into sub-expressions.
- `Accessor` — compared by field name.

Every other constructor (`Negate`, `Lambda`, `Let`, `LetRec`, `LetDestruct`, `Case`, `Update`,
`Record`, `Shader`, `VarDebug`, `VarForeign`, `VarOperator`) makes `sameExpr` return `False`
unconditionally for that pair, even if both sides happen to use the same one — these forms either
introduce their own bindings (subtler aliasing questions, deliberately deferred) or are rare/complex
enough that comparing them isn't worth the risk for this first version. Returning `False` only ever
*misses* a sharing opportunity; it can never cause an incorrect merge, so this restriction is free
to make generously.

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

- `compiler/src/Optimize/Expression.hs` — new `bindsNoVariables`/`sameExpr` helpers; the
  `Can.Case expr branches` handling (and `optimizeTail`'s mirror) changes how target indices are
  assigned to branches before calling `Case.optimize`.
- `compiler/src/Optimize/Case.hs` — **no changes**.
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
  definitions at all, only adds ordinary functions in `Optimize/Expression.hs`.
