# Design: Optimization Research Sweep

## Goal

Find new JS-codegen optimization candidates for the Elm compiler fork beyond the ones already
explored (see `CLAUDE.md` / memory index: TRMC, unwrapped HOFs, ADT shape padding, list fusion
v1/v2, bare producer chains, kernel list padding, record update inlining, prim-binop
specialization, local arity call bypass — all committed; closed-lambda-hoisting,
partial-application-callback, html-tag-arity, list-foldr-fusion — all spiked and discarded).

Research online, generate candidate ideas, spike and benchmark each one, and document findings —
without committing any change to the actual Haskell compiler in this pass.

## Phase 1 — Research

Two parallel research tracks:

1. **V8 internals** — current V8 blog posts/talks on hidden classes, inline caches, TurboFan
   inlining limits, GC/allocation behavior. Purpose: understand what V8 already optimizes well
   (to *exclude* dead-end candidate classes) versus what it demonstrably does not eliminate on its
   own.
2. **Other FP→JS compilers** — PureScript, ReScript/BuckleScript, Gleam, Roc, Fable. How do they
   compile pattern matching, currying/arity, record representation, tail calls? Any structurally
   different approach than Elm's current codegen is a candidate.

**Filtering criterion from project history:** three prior spikes (closed-lambda-hoisting,
partial-application-callback, html-tag-arity) independently found that V8 already optimizes
monomorphic call sites (same target value at the same call-site text) almost perfectly, regardless
of whether the dispatch uncertainty comes from currying, unregistered kernel arity, or closure
allocation. Ideas in the "bypass call-site dispatch overhead" class are deprioritized. What *did*
pay off historically: eliminating allocations/traversals entirely (list fusion, shape padding,
record update inlining) or changing the algorithmic shape (TRMC). Research should target more of
the latter.

## Phase 2 — Spikes

No cap on candidate count — pursue as many as the research turns up that pass an initial
plausibility check. For each candidate, reuse the project's established spike methodology:

- Scratch project outside the repo (session scratchpad), not committed.
- Hand-patched before/after JS variants (no compiler rebuild needed, unless a candidate genuinely
  requires real compiler output to validate — as the bare-producer-chain-fusion spike did).
- Correctness check via checksum or structural comparison between variants.
- Interleaved timing across **separate Node processes** (not just separate runs in one process).
- Multiple input sizes.
- Enough repetitions per process to avoid measurement noise — lesson from html-tag-arity-spike:
  target ~500ms-1s single-process runtime, not 100-150ms, since short runs produced a false
  positive (~2.8%) that vanished under closer measurement.

## Phase 3 — Documentation

Every candidate gets a memory entry (positive / negative / conditional verdict) following the
existing spike-memory format, regardless of outcome. No changes land in the actual Haskell
compiler in this pass — that remains a separate follow-up (design + implementation plan) for any
candidate that comes out clearly positive. End of sweep: a summary of all candidates spiked, their
verdicts, and a recommendation on which (if any) merit a follow-up implementation plan.

## Explicitly out of scope

- Modifying `compiler/`, `builder/`, or any other Haskell source in this pass.
- Elm-ecosystem/community research (elm-optimize-level-2, elm/compiler issues) — deferred, not
  part of this sweep.
- A hard cap on the number of candidates spiked.
