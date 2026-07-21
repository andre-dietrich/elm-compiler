# Optimization Research Sweep — Summary

Closes out the 6-task sweep described in
`docs/superpowers/specs/2026-07-21-optimization-research-sweep-design.md`. Five candidates were
researched, hand-patch-spiked, benchmarked, and reviewed. No Haskell compiler code was changed in
this pass — that was explicitly out of scope (design goal, Phase 3). This document is the
aggregate result and the recommendation for what (if anything) should become a real
design+implementation-plan cycle next.

## Candidates and verdicts

| # | Slug | Verdict | Headline number(s) |
|---|------|---------|---------------------|
| 1 | `mutual-tailcall-cycle-fusion` | **POSITIVE** (two axes, different confidence) | Robustness: unfused mutually-tail-recursive 2-function cycle crashes (`RangeError: Maximum call stack size exceeded`) between N=5,000 and N=8,000 bounces; fused version runs crash-free flat to N=10,000,000 (38.7ms) — categorical, unaffected by the correction below. Speed (corrected after rigor review removed an incidental `modBy`→`%` inlining confound): ~6-8% at N=100 (near noise floor but reproduced over 3 runs), ~23-27% at N=1,000 (robust), ~9-11% at N=5,000 (clear but smaller than originally reported) — size-dependent, no losing regime. |
| 2 | `decision-tree-dag-sharing` | **Two sub-verdicts**: (A) DAG-sharing **POSITIVE**; (B) cold-branch outlining **POSITIVE BUT CONDITIONAL** | (A) 1.40x-1.46x, flat across 4 orders of magnitude (1e3-1e6), confirmed not a dead-code artifact via control variant. (B) 1.05x-1.12x under skewed call traffic (95% of calls hit 3 of 36 constructor tags) — but 0.92x-1.00x (a **regression**) under uniform traffic across the same 36 tags, reproduced over 2 independent runs at 3 of 4 sizes (4th size at the noise floor in run 2). |
| 3 | `static-shape-record-clone` | **POSITIVE** | `Object.assign` replacing the `for...in` copy-loop: 2.7x-5.4x, scaling with field count (2.74x-2.92x at 4 fields, 4.99x-5.42x at 12 fields). Fully static object literal (closed field set known): 8.76x-14.0x, independent of whether an IIFE wrapper is kept. Flat across all four tested sizes (1e3-1e6) for both variants. |
| 4 | `closed-type-structural-equality` | **POSITIVE** | 2.0x-3.3x replacing generic `_Utils_eq` walk with flat `===` chains (record) / tag-switch + flat field `===` (union), consistent across sizes 1e3-1e6 and both record and closed-union shapes (record: 2.03x-2.44x; union: 2.23x-3.27x). |
| 5 | `array-index-adt-tuple-repr` | **NEGATIVE** | Array/index representation (`[tag, a, b]`) is *slower* than the already-shipped padded object representation in every tested size and both sub-cases: combined 0.75x-0.81x, ADT-only 0.74x-0.88x, pure-tuple-only (best case for the hypothesis, no null padding) 0.67x-0.99x — never a win, up to -33% in the worst case. |

## Recommendation

### Scope reminder

This sweep was research-and-spike only (Task brief / design doc, Phase 2-3): every "POSITIVE" or
"CONDITIONAL" verdict below is a **candidate for a future design+implementation-plan cycle**, not
an approved change. None of these have touched `compiler/` or `builder/` Haskell sources. Turning
any of them into a shipped optimization requires going through the project's normal
design-doc → implementation-plan → review cycle, same as `trmc-plan`, `tier2-record-update-spike`,
etc. were before they landed on `main`.

### Prioritization across the positive/conditional candidates

Ranked by a rough expected-value read — measured magnitude, weighted down by the implementation
cost each memory file itself discloses (type-system plumbing, new compiler infrastructure, codegen
scope) — not by magnitude alone:

1. **`static-shape-record-clone`, `Object.assign` tier — highest priority.** Best cost/benefit ratio
   in the whole set: a solid 2.7x-5.4x win that the memory file states explicitly needs **no
   `AST.Optimized`/wire-format change** — it is a localized swap inside `generateInlineUpdateBody`.
   Lowest implementation risk, immediately actionable, no new infrastructure required.
2. **`static-shape-record-clone`, static-literal tier — natural phase 2 of the same initiative.**
   Substantially bigger win (8.8x-14x, ~3-5x better than the `Object.assign` tier) but requires real
   feature design: the record type's full closed field set must be threaded from type-checking
   through to `Optimize.Expression`/`Opt.Update`, which today only carries the *changed* fields.
   The memory file notes the data already exists for exhaustiveness checks in `Nitpick` but isn't
   available at the `Opt.Update` construction site — a plumbing job, not a research question, and a
   reasonable second phase once tier 1 ships.
3. **`decision-tree-dag-sharing`, sub-mechanism (A) DAG-sharing.** Robust, flat 1.40x-1.46x with an
   unusually clean confidence bar (explicitly verified not to be a dead-code-elimination artifact via
   a dedicated control variant). Moderate implementation cost: extends the *existing* Jump/Inline
   leaf-sharing mechanism in `Optimize/Case.hs`/`Optimize/DecisionTree.hs` to whole structurally-
   identical sibling subtrees, rather than inventing a new mechanism from scratch — lower novelty
   risk than the other candidates below.
4. **`closed-type-structural-equality`.** Comparable or larger raw magnitude (2.0x-3.3x) to #3, but
   ranked below it because its own memory file discloses the heaviest type-system plumbing burden of
   the batch: `toPrimType` must be extended with a recursive closedness proof over arbitrary record
   field / union payload types that correctly excludes type variables, row polymorphism, and
   (importantly) real recursion, without which the optimization risks being applied unsoundly. This
   is genuine, non-trivial type-system design work, not just codegen — the magnitude justifies
   pursuing it, but expect the design phase alone to be substantial.
5. **`mutual-tailcall-cycle-fusion`.** Ranked last among the positives on a magnitude/cost basis, but
   for a distinct reason worth flagging separately: its speed axis is the smallest and most
   size-dependent of the batch (best case ~23-27% at N=1,000, falling to ~9-11% at N=5,000 and
   barely-above-noise at N=100), and the implementation is the most architecturally novel — SCC
   detection over the call graph for mutually-tail-recursive top-level bindings, synthesis of a
   fused mode-dispatching function, thin per-member wrapper generation, and interaction with the
   existing self-tail-call optimization. This is comparable in scope to the already-shipped
   `trmc-plan` work, which took real design effort. That said, its **robustness axis is categorical
   and independent of the speed question** — it eliminates a real stack-overflow risk for idiomatic
   mutually-recursive Elm code (hand-written recursive-descent parsers, step-machines) at a
   realistic N (~5,000-8,000), not just a pathological one. A team that weights crash-safety over
   raw throughput could reasonably move this to #1; ranked here on a magnitude-per-effort basis, but
   the correctness case stands on its own regardless of the speed numbers.
6. **`decision-tree-dag-sharing`, sub-mechanism (B) outlining — lowest priority, and not safe to
   pursue as-is.** Unlike the other CONDITIONAL/POSITIVE entries, this one is only a net *win* under
   a real precondition (traffic skew: ≥95% of calls landing on a small subset of constructors) and a
   proven net *regression* (0-8%, reproduced) otherwise. Implementing it without also building a
   skew-detection heuristic (constructor-call-frequency profiling or a similar static signal) would
   make it a compiler that sometimes silently regresses code with no way for the user to know why.
   Any implementation plan for this one must treat the heuristic as a first-class, load-bearing
   piece of new infrastructure, not an optional refinement — which is real extra scope beyond what
   sub-mechanism (A) needs. Only worth picking up if a skew-detection signal becomes independently
   useful, or as a deliberately lower-priority stretch item bundled with (A).

### The one closed-out candidate

**`array-index-adt-tuple-repr` is closed, not a candidate for later.** It is the sweep's one clean
NEGATIVE: the array/index representation loses in every tested size and in both the ADT case (mixed
with null-padding) and the pure-tuple case (the theoretically most favorable case for the
hypothesis, with no null-padding at all) — up to -33% in the worst observed case, never a win. The
memory file's own mechanistic explanation is that the already-shipped `adt-shape-padding-plan` work
already solved the V8 hidden-class fragmentation problem this candidate targeted, and named-property
access on the resulting small, fixed, monomorphic object shapes is already close to V8's practical
optimum — there is no headroom left for an array-based representation to win, and the full
implementation cost (rewriting every kernel JS consumer of ADT/tuple shape: `_List_Cons`, `Dict`,
`_Utils_eq`, `Debug.toString`, JSON codecs, `DecisionTree`/`Case` codegen) was never even reached
because the core mechanism already lost before that cost would be paid.

## Process learning

The sweep's own rigor process caught two real measurement problems before they were accepted as
final results, not just as a formality:

- **`mutual-tailcall-cycle-fusion`**: an independent rigor review found that the hand-patched
  "after" variant had accidentally inlined `A2($elm$core$Basics$modBy, ...)` to a raw `%` operator
  alongside the intended control-flow fusion — a second, unrelated optimization riding along in the
  same diff and inflating the reported speedup (originally up to ~1.17-1.21x at N=5,000, corrected
  down to ~1.09-1.11x once the `modBy` confound was isolated out). The fix required a fresh
  "pure-fusion" variant and three new independent measurement runs.
- **`decision-tree-dag-sharing`**: a rigor review caught that the outlining sub-experiment's
  narrative claimed "2 independent runs for both distributions" when in fact only the skewed side
  had 2 runs — the uniform-traffic control had only 1. A second independent run was performed before
  the CONDITIONAL verdict was finalized; it confirmed the regression at 3 of 4 sizes and found the
  4th size at the noise floor rather than a clear regression, refining (not reversing) the original
  claim.

Both corrections happened *before* the candidate's memory file was accepted as final, which is the
intended function of the review step baked into this sweep's methodology, not an incidental
byproduct.
