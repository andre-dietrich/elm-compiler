# Decision-Tree DAG Sharing — Design Spec

**Date:** 2026-07-22
**Status:** Approved for planning

## Background

The [[decision-tree-dag-sharing-spike]] (2026-07-21, memory) hand-patch-benchmarked a JS-level
simulation of this optimization and found a robust 1.40x-1.46x speedup, flat across four orders of
magnitude of input size, with a control run ruling out dead-code elimination as the source of the
gain. This spec turns that finding into a real compiler change ("Mechanism A" from that spike;
"Mechanism B", cold-branch outlining, was found conditional/regressive under uniform call-site
traffic and is explicitly out of scope here).

**Root cause in the current compiler:** `Optimize.Case.treeToDecider` (`compiler/src/Optimize/Case.hs`)
converts a `DT.DecisionTree` into an `Opt.Decider Int` by recursing independently over every sibling
edge (`map (second treeToDecider) edges`). When a case expression's decision tree contains two or
more sibling branches whose *nested* test structure is byte-for-byte identical — for example
`case (status, priority) of (Pending, Low) -> ...; (Active, Low) -> ...` where the `priority`
sub-match is identical under both `Pending` and `Active` — the compiler emits that nested
test-and-dispatch structure once per occurrence instead of once, shared. The existing sharing
mechanism (`countTargets`/`createChoices`/`Opt.Jump`) only dedupes identical **leaves** (final
branch bodies reached by exactly-matching target index), never dedupes identical **interior**
`Chain`/`FanOut` nodes.

## Goal

Detect structurally-identical `Chain`/`FanOut` subtrees within a single `Opt.Case`'s decision tree
and compile them once, with all occurrences sharing that one compiled form — generalizing the
existing leaf-sharing mechanism from "identical final expression" to "identical decision subtree."

## Non-goals

- Sharing across *separate* `Opt.Case` AST nodes (e.g. two textually-identical nested
  `case`-of-`case` expressions written out under different outer arms). That is a general
  cross-expression CSE problem, was not what was spiked, and is out of scope.
- Cold-branch outlining (spike Mechanism B) — conditional/regressive, not part of this plan.
- Any whole-program or `Mode`-dependent analysis. This transformation runs identically for
  `Mode.Dev` and `Mode.Prod`.

## Architecture

The transformation lives entirely in `compiler/src/Optimize/Case.hs`. `optimize` changes from a
pure function to one running in `Optimize.Names.Tracker` (`compiler/src/Optimize/Names.hs`),
matching the convention `Optimize.Expression` already uses to mint fresh, collision-free names
(`Names.generate`) — needed here to name the nested `Opt.Case` a shared subtree gets packaged into.

Pipeline, per call to `Case.optimize`:

1. Build `decider0 :: Opt.Decider Int` via the existing `treeToDecider (DT.compile patterns)` —
   unchanged.
2. **New — subtree-sharing pass:** walk `decider0` bottom-up. At each `Chain`/`FanOut` node, check
   whether a structurally-identical node has already been seen elsewhere in the same tree (via
   `Opt.Decider`'s existing `Eq` instance; add `Ord` for efficient grouping in a `Map` — internal
   use only inside this pass, no `Binary`/serialization impact). Every occurrence of a duplicate
   (all of them, not just the second-onward) is replaced by `Leaf freshTarget`, where `freshTarget`
   is a synthetic index above the real branch index range (`>= length optBranches`). Bare `Leaf`
   nodes are left untouched — the existing target-based Leaf/Jump sharing already covers those and
   this pass must not interfere with it.
3. For each extracted duplicate subtree, treat it as its **own self-contained case problem**,
   independent of the outer tree (see Correctness invariant below):
   - Compute target counts scoped to *only* that subtree (a local `countTargets` over the extracted
     `Decider Int`, not the outer tree's counts).
   - Build its own local choice map (`createChoices`/`insertChoices`) from those local counts.
   - Mint a fresh label via `Names.generate`.
   - Package the result as `Opt.Case innerLabel root innerDeciderChoice innerJumps` — an ordinary
     `Opt.Expr`.
4. This packaged `Opt.Case` becomes the branch expression for `freshTarget` in the **outer**
   `optimize` call's jump list. The outer tree proceeds through the existing
   `countTargets`/`createChoices`/`insertChoices` exactly as today (using `decider0` with the
   duplicate subtrees already collapsed to `Leaf freshTarget` in step 2), with the synthetic jump(s)
   appended to its `jumps` list.

No changes to `AST.Optimized`'s data types and no `.elmo`/`.elmi` binary-format bump: a shared
subtree is represented as an ordinary nested `Opt.Case` value, which the AST and
`Generate.JavaScript.Expression` already fully support with zero changes to that module — a shared
subtree compiles via the exact same `Opt.Case label root decider jumps -> JsBlock $ generateCase
mode label root decider jumps` clause that handles every other case expression.

### Why this is codegen-safe (label/break scoping)

`Generate.JavaScript.Expression.generateDecider` threads a single `label` parameter through its
entire recursive walk of one `Opt.Case`'s decider tree; every `Opt.Jump index` leaf reached during
that walk compiles to `break <label>$index`, and the matching `<label>$index: while(true){...}`
wrapper is emitted once per entry in that *same* `Opt.Case`'s own `jumps` list
(`Generate.JavaScript.Expression.goto`). A `Jump` can therefore never reference an ancestor
`Opt.Case`'s label — jump scoping is always local to whichever single `Opt.Case` node's decider a
leaf lives in. This is exactly why packaging a shared subtree as its own nested `Opt.Case` (with
its own label and its own jump list) is safe: it is fully self-contained by construction, and
nothing about its internal `Jump`s can leak into or collide with the outer tree's labels.

## Correctness invariant

A shared subtree's local jump analysis **must** be computed independently of the outer tree's
target counts — never by reusing the outer tree's global `countTargets` result. If it were reused,
a target reached exactly once *within* the shared subtree, but that also happens to recur elsewhere
in the outer tree outside the subtree, would be miscounted and could be assigned a `Jump` whose
`break` target is never defined in the (locally self-contained) nested `Opt.Case`'s own `jumps`
list — a silent JS `ReferenceError`/incorrect-label bug at runtime, not something the Haskell type
system would catch.

The resolution (already reflected in the Architecture pipeline above): treat every extracted
subtree as its own independent case problem with its own local counts/choices/jumps, computed
fully separately from the outer tree's. If the same original branch target is reachable both inside
a shared subtree and independently outside it, its `Opt.Expr` body is compiled twice — once in each
independent scope. This is an accepted, pre-existing tradeoff class: the current mechanism already
duplicates `Inline`d bodies whenever they're used at multiple non-shared positions.

This is the one place a bug would be easy to introduce and hard to spot from casual testing, so the
implementation plan's manual test fixtures must include a case that specifically exercises it: a
branch target that occurs twice inside one duplicate subtree *and* once more outside it.

## Components touched

- `compiler/src/Optimize/Case.hs` — `optimize` becomes `Names.Tracker Opt.Expr`; new internal
  subtree-detection-and-extraction helper(s) (naming left to the implementation plan).
- `compiler/src/Optimize/Expression.hs` — the ~4 call sites of `Case.optimize` (two in the ordinary
  `Can.Case` branch, two in the TRMC/tail-call hole-mutation path around line 1190/1336) change from
  `<$>`/plain application to monadic binds.
- `compiler/src/AST/Optimized.hs` — one-line addition: `deriving (Eq, Ord)` on `Decider` (currently
  `deriving (Eq)` only).
- `compiler/src/Generate/JavaScript/Expression.hs` — **no changes**. Already handles nested
  `Opt.Case` values wherever they appear as an `Expr`.

## Testing strategy

No automated test suite exists in this repository (see `CLAUDE.md`). Verification is manual,
following the project's established pattern:

1. Build the compiler via the Docker toolchain (`CLAUDE.md` build recipe).
2. Hand-written scratch `.elm` fixtures (outside the repo, in the session scratchpad), covering:
   - The motivating case: a tuple/multi-argument match with a duplicated inner sub-match across
     multiple outer arms (the `(status, priority)` shape from the earlier discussion).
   - The correctness-invariant edge case: a branch target reachable both inside a duplicate
     subtree and independently outside it.
   - A case with **no** duplication, as a regression check — generated JS must be unchanged
     (or trivially/semantically equivalent) versus the pre-change compiler.
3. Execute all fixtures under Node to confirm runtime behavior is correct.
4. Diff/inspect generated JS for both plain `elm make` (Dev) and `elm make --optimize` (Prod)
   output.
5. Re-run the original spike's interleaved-process benchmark harness against the **real** compiler
   output (not hand-patched JS) for the motivating case, to confirm the 1.40x-1.46x finding holds
   end-to-end.

## Risks

- **Correctness invariant above** — the main real risk, mitigated by a dedicated test fixture.
- **Fresh-name plumbing ripple** — changing `Case.optimize`'s signature touches every call site;
  mechanical but must be done at all ~4 sites, including the TRMC hole-mutation path, without
  breaking that unrelated feature.
- **No format/`.elmo` risk** — explicitly designed to avoid this class of risk (see Architecture).
