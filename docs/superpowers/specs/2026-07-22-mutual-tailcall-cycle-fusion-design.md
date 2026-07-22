# Design Spec: Mutual-Tail-Call Cycle Fusion

## Motivation

Nutzen-Check-Spike (session scratch `mutual-tailcall-cycle-fusion-spike`, 2026-07-21, memory:
`mutual-tailcall-cycle-fusion-spike.md`): a hand-fused JS rewrite of two mutually tail-recursive
top-level functions (`stepA n acc = if n<=0 then acc else stepB (n-1) (acc+1)`, `stepB` symmetric)
into one JS function with a `mode` variable and a `while(true)` loop was benchmarked against the
compiler's current (unfused) output. Two independent findings, both confirmed over multiple
interleaved runs:

- **Robustness (categorical):** the unfused variant crashes with `RangeError: Maximum call stack
  size exceeded` between N=5,000 and N=8,000 bounces (binary-search-verified) and at every larger N
  tested up to 10,000,000; the fused variant runs crash-free at every N, flat stack depth
  (N=10,000,000 in 38.7ms). No JS engine implements proper tail calls across independent function
  objects, so this is not something V8 will ever close on its own.
- **Speed (real, size-dependent, isolated from a confounding modBy-inlining bug found by a rigor
  review):** ~1.06-1.08x at N=100 (near noise floor), ~1.23-1.27x at N=1,000 (robust), ~1.09-1.11x
  at N=5,000 (clear but moderate).

Full spike methodology and the confound correction: memory `mutual-tailcall-cycle-fusion-spike.md`.

This is categorized the same as the committed TRMC work ([[trmc-plan]]): not a dispatch-bypass, but
an algorithmic shape change (recursion → iteration) that no downstream JS engine optimization could
ever replicate, plus (unlike TRMC) a correctness/robustness angle — idiomatic mutually-recursive
Elm code (hand-written recursive-descent parsers, step-by-step state machines) currently has an
unadvertised stack-overflow ceiling around 5-8k bounces that this eliminates categorically.

## Scope: general N-member SCCs, not just pairs

An earlier draft of this spec scoped the first cut down to exactly 2-member cycles, reasoning that
it was the only case actually benchmarked and would be simpler to implement. Re-examining that
assumption (at the user's request) found the restriction bought little:

- **Detection is the same code either way.** `Data.Graph.stronglyConnComp` (already used for
  exactly this class of problem in `Canonicalize/Module.hs:81-99`, `Canonicalize/Environment/Local.hs`,
  `builder/src/Build.hs`) takes a `[(node, key, [key])]` edge list and returns `[Graph.SCC node]`
  directly. `Graph.CyclicSCC subNodes` with `length subNodes >= 2` are exactly the fusion
  candidates, at any size — there is no "just handle 2" special case to write; restricting to pairs
  would have meant *adding* a hand-rolled mutual-check instead of reusing this.
- **The pairwise restriction introduces an ambiguity problem the general version doesn't have.** If
  function A qualifies for more than one pair (A↔B and A↔C both directly mutual), a pairwise scheme
  needs an arbitrary tie-break ("first pair in def order wins"). A true SCC partition is canonical:
  every node belongs to exactly one SCC, full stop.
- **Codegen generalizes without a new mechanism.** The "reusing a JS variable across cases is safe
  because every transition into a case fully reassigns that case's own parameter names before use"
  argument (see below) is proved per transition edge, not per cycle size. `switch(mode)` with N arms
  instead of 2, and wrapper generation with positional padding for non-shared parameter names, are
  both linear-in-N, not combinatorial.
- **The IR node is simpler as a list than as a hardcoded pair** — `[(Name, [Name], Expr)]` needs no
  later rework to generalize; a `FusedPair` tuple would.

What N *does* add, honestly: more test surface (harder to hand-verify a 5-way switch than a pair),
and the SCC computation now needs to run **twice** (see Algorithm) since real fusability can only be
confirmed after the widened tail-call optimize pass runs — but that is the same reusable
`stronglyConnComp` call made a second time, not new logic.

**In scope:** any strongly-connected set of ≥2 top-level functions, of any size, mixed arities,
found within a single existing `Opt.Cycle` node (i.e. a single `Can.DeclareRec` group — cross-module
cycles are not possible in Elm's import model, so this never needs to reach across modules).

**Out of scope for this plan:**
- Any interaction with Tail-Recursion-Modulo-Cons (`TailCallCons`/TRMC). A function with a detected
  cons identity (`detectConsIdentity` returns `Just`) is excluded from fusion-candidacy entirely,
  before the candidate graph is even built — it keeps its existing solo TRMC codegen, unchanged.
  Combining TRMC's sentinel/hole-mutation loop shape with cross-function mode dispatch is a
  plausible future extension, not attempted here.
- Non-cyclic tail chains (A tail-calls B, but B never — directly or transitively — tail-calls back
  to A). These have no stack-growth risk under repeated bouncing (the chain runs once per outer
  call, doesn't loop), so there is no robustness case for them, and no hot-loop to speed up. They
  correctly fall out of the SCC computation as separate `AcyclicSCC` nodes and are left as ordinary
  `Opt.Call`s, exactly as today.
- Any change to how 0-argument mutually-recursive top-level **values** are handled
  (`Opt.VarCycle`/the existing `Opt.Cycle` "values" list, `generateSafeCycle`/`generateRealCycle`).
  That mechanism answers a different question (lazy-init cyclic values) and is untouched.

## Algorithm

Runs inside `Optimize.Module.addRecDefs`, once per `Can.DeclareRec` group, operating only on the
subset of that group's defs that take ≥1 argument (the existing `funcs`/`values` split already made
there).

**1. Pre-filter.** Any candidate function with `detectConsIdentity name argNames body /= Nothing`
(TRMC-eligible) is removed from the candidate set up front — it goes through today's unmodified
`optimizePotentialTailCall` path, solo.

**2. Optimistic edge scan.** For each remaining candidate function, a lightweight, purely syntactic
walk over its (un-optimized) `Can.Expr` body — structurally identical to `optimizeTail`'s own
traversal shape (`Can.If`/`Can.Let`/`Can.LetRec`/`Can.LetDestruct`/`Can.Case` recursed into tail
position, everything else ignored) — collects the *set of names called in tail position*, with no
Names.Tracker side effects and no arity checking yet. Self-loops (a function calling itself) are
dropped from this edge set — self-recursion is already handled by the existing, unmodified
self-`TailDef` mechanism and never needs to enter the fusion graph.

**3. First SCC pass.** Feed `[(name, name, [tail-called candidate names])]` to
`Graph.stronglyConnComp`. Every `Graph.CyclicSCC subNames` with `length subNames >= 2` is a
*candidate cluster*. (`AcyclicSCC` and size-1 `CyclicSCC` — the latter would only arise from a
self-loop, already excluded in step 2 — are left untouched.)

**4. Widened real optimize.** For each candidate cluster, run the existing `optimizeTail` machinery
once per member, but with the single-`rootName` match (`matchTailSelfCall`'s
`rootName == name` check) generalized to a lookup against a `Map Name.Name [Name.Name]` of *all*
cluster members' own argument-name lists. A tail-position `Can.Call` to any cluster member (self or
sibling) — arity-matched against **that member's own** argument list, not the caller's — becomes
`Opt.TailCall targetName pairs`, exactly the existing node, just now legitimately pointing at a
different function. A call whose arity doesn't match still falls back to plain `Opt.Call`, exactly
as `matchTailSelfCall` already does today for the self-only case — no new fallback logic needed.

**Note on `Opt.TailCall` reuse:** step 4 reuses the existing `Opt.TailCall` constructor as-is for every widened match (self or sibling) — it does not yet need a dedicated fused-call node. `Opt.TailCall`'s *codegen*, however (`generateTailCall`, a labelled `continue <target's own name>`), only makes sense for a target that owns its own enclosing labelled loop, which is true for self-recursion but not for a sibling folded into a shared function — so confirmed clusters get a **second, dedicated** `Opt.Expr` constructor at packaging time (step 6), produced only by a rewrite over already-built `Opt.TailCall` nodes, never by `optimizeTail` directly. See Codegen/New IR below for why a plain shared `continue;` (no label at all) is sufficient and correct once every member lives in one switch inside one loop.

**5. Confirmation SCC pass.** The optimistic scan in step 2 can overshoot (e.g. a tail-position call
that turns out arity-mismatched, so step 4 emitted a plain `Opt.Call` instead of `Opt.TailCall`).
Build a second edge list from the **actual** `Opt.TailCall` targets present in each member's
now-optimized body (a `collectTailCallTargets :: Opt.Expr -> Set Name` walk, same shape as the
existing `hasTailCallCons`/`hasTailCall` walks), restricted to the same candidate cluster, and run
`Graph.stronglyConnComp` again. Only `CyclicSCC`s of size ≥2 surviving this second pass are actually
packaged as fused; anything that shrank below 2 falls back to that member's normal, unfused
`toTailDef` output (its `Opt.TailCall`s to no-longer-clustered siblings, having already been
generated as real `Opt.TailCall` nodes in step 4, must be re-optimized as plain `Opt.Call` instead —
concretely, simplest correct implementation is: if the confirmation pass rejects a cluster, discard
step 4's output entirely and re-run each member through today's *unmodified*
`optimizePotentialTailCall` (self-only matching), rather than trying to patch the widened output
back down).

**6. Packaging.** Confirmed clusters become one new `Opt.Node` (see below) holding each member's
`(Name, [Name] argNames, Expr body)` triple — the *raw* tail-optimized body, **not** wrapped by
`toTailDef`'s `TailDef`/label+while machinery (that machinery produces a self-contained JS function
per member; fused members instead become one `case` arm inside a single shared function — see
Codegen). Everything else in the `Can.DeclareRec` group — non-candidate functions, TRMC functions,
unfused candidates, 0-arg values — is packaged exactly as `addRecDefs` does today.

## New IR

`AST.Optimized.Node` gains:

```haskell
| FusedCycle [(Name.Name, [Name.Name], Expr)] (Set.Set Global)
```

`AST.Optimized.Expr` gains a dedicated fused-jump node, produced only by the packaging rewrite in
step 6 (never directly by `optimizeTail`):

```haskell
| TailCallFused Name.Name Int [(Name.Name, Expr)]
```

(cluster-identity name — a fixed anchor, deterministically the first member in the cluster's
stored order, used only to derive the shared JS `mode` variable's name, exactly the same role
`TailDefCons`'s trailing `Name` already plays for deriving sentinel-variable names; target mode
index; the target's own argument-name/value pairs to reassign). Its codegen is a plain, **unlabelled**
`continue;` — safe and sufficient because a fused member's body always lives inside exactly one
shared `while(true)`/`switch`, so there is never a nested loop for an unlabelled `continue` to
ambiguously target (checked directly: Elm's own case-expression decision trees, `Optimize.Case`,
compile to `JS.Switch`/labelled `JS.Break`, never `JS.Continue`, so nesting a decision tree inside a
fused case arm cannot collide with this).

**Confirmation policy (v1 simplification):** if a first-pass candidate cluster of size N doesn't
survive the second (confirmation) SCC pass **as one intact group of the same N members**, the whole
group is rejected and every member falls back to the normal, unfused path — even if a strict subset
of it (e.g. 2 of 3) would have confirmed on its own. Handling partial survival correctly would
require iterating the widen/confirm cycle to a fixed point (removing one member can shrink another's
matchable-target set, changing what *its* next confirmation pass would find), which is real added
complexity for a case only arity-mismatches can trigger. All-or-nothing per attempted cluster is
strictly conservative (never wrong, only occasionally more cautious than theoretically possible) and
kept explicit here so the implementation plan doesn't have to rediscover this trade-off.

(member name, its own argument names, its tail-optimized body; the `Set Global` is the union of all
members' dependencies, same role as every other node's dep set). Stored under a synthetic combined
`Global` name (`Name.fromManyNames` over the member names, mirroring `Opt.Cycle`'s existing
`cycleName` pattern exactly), with each original member name `Link`-ed to it — reuses the exact
`links`/`Map.union` wiring `addRecDefs` already does for `Opt.Cycle`, so external callers, dead-code
elimination, and dependency-graph traversal all keep working through the existing `Link`-following
in `addGlobalHelp` without changes there.

**`.elmo`/`.elmi` format changes** (accepted cost, same as every prior IR-changing plan in this
repo — [[static-shape-record-clone-plan]], [[adt-shape-padding-plan]] before it): one new `Node`
constructor tag (11) in `Binary Node`'s `put`/`get`, and one new `Expr` constructor tag (30) in
`Binary Expr`'s `put`/`get`. No change to any *existing* constructor's shape in either type.

**Not every `case` over `Opt.Node` (or `Opt.Expr`) is compiler-enforced exhaustive** — checked directly rather than
assumed, since this repo's `-Wall -Werror` (per CLAUDE.md) only catches a missed constructor where
the `case` has no wildcard arm:

- **Compiler-enforced** (adding `FusedCycle` without touching these fails the build):
  `Generate/JavaScript.hs`'s `addGlobalHelp` (11 arms, no wildcard, one per current constructor);
  `Nitpick/WorkerRegistry.hs`'s `nodeTargets`; `Nitpick/Debug.hs`'s `nodeHasDebug` (same pattern,
  both fully enumerated, no wildcard).
- **Not compiler-enforced — silent-degrade risk, needs manual attention:**
  `Generate/Mode.hs`'s `nodeArity` ends in `_ -> Nothing` (compiles fine either way). Missing this
  one doesn't produce wrong output — a `FusedCycle` member's wrapper would just fall back to
  generic `A2..A9`-dispatch treatment from outside the cycle, the same as any global the compiler
  can't prove a static arity for — but it silently gives up the existing direct-call/unwrapped-HOF
  bypass for calls into a fused member from outside its cycle, which this plan should not
  regress. Needs an explicit `Opt.FusedCycle members _ -> findFusedArity name members` arm (mirroring
  the existing `cycleArity`/`findDefArity` pair, which only knows about `Opt.Cycle`) added
  deliberately, plus a note in the implementation plan to grep for any other `Opt.Node` pattern
  match with a trailing wildcard before considering this done.

## Codegen

One new JS function per confirmed cluster — call it `_fused$<combined name>` — built as:

```js
function _fused$stepA$stepB(mode, n, acc) {
  while (true) {
    switch (mode) {
      case 0: /* stepA's body */
      case 1: /* stepB's body */
    }
  }
}
var stepA = function(n, acc) { return _fused$stepA$stepB(0, n, acc); };
var stepB = function(n, acc) { return _fused$stepA$stepB(1, n, acc); };
```

**Shared parameter list, by name identity, not position.** The fused function's formal parameters
are the deduplicated union of every member's own argument names (member order, first-seen). No
alpha-renaming pass over `Opt.Expr` is needed. This relies on one invariant, provable per edge
rather than per cycle-size: **every transition into member M's `case` arm is preceded by a complete
assignment of M's own parameter names** — either by an entry wrapper's initial call (which always
supplies all of M's own args), or by `Opt.TailCall`'s existing codegen (`generateTailCall`,
unchanged), which already assigns *every* name in the target's `argNames` list via temp-vars-then-
real-vars (to get simultaneous-assignment semantics for self-recursive rebinds, e.g. `swap n acc =
swap acc n`) before the `continue`. Two members that happen to reuse the same argument name (as
`stepA`/`stepB` do in the benchmarked case — both use `n`/`acc`) simply share that JS variable slot;
this is provably safe by the same invariant, not a coincidence to guard against. Members with a
parameter name **not** shared by any other cluster member still need a JS parameter slot in the
fused function's signature; any wrapper for a *different* member that doesn't use that name passes
`undefined` in that position (mechanical, computed once from the union list's fixed member→position
map — no dynamic dispatch, no boxing).

**Self-recursion inside a fused member needs no special case.** If member A also tail-calls itself
directly (in addition to mutually tail-calling B), that self-call is just another `Opt.TailCall`
whose target happens to equal the enclosing `case` arm's own name — codegen is uniform regardless:
assign the target's params, set `mode` to the target's case index (same value, if self), `continue`
the one shared `while` loop. No branch on "is this a self-call or a cross-call" is needed anywhere
in codegen.

**Mode-independent.** Like the existing self-`TailDef` mechanism (already applied identically in
Dev and Prod — confirmed by reading `generateTailDef`, which takes no `Mode`-conditional branch), this
is a pure `Optimize`-phase AST/IR shape change; `Generate.Mode`'s Dev/Prod split never needs to know
fusion happened. Satisfies this repo's CLAUDE.md constraint that Prod-specific codegen must never
change Dev output — this isn't Prod-specific to begin with.

## Why this is semantics-preserving

- Every fused member is reachable from outside the cluster only through its own unchanged-arity
  thin wrapper — external call sites, partial application, `Debug.toString`-visible identity, and
  dead-code-elimination reachability are all unaffected; the wrapper *is* the function as far as
  the rest of the program can tell.
- The `case`-arm bodies are exactly what `optimizeTail`/`toTailDef` would have produced for each
  member standing alone, with the sole difference being which names count as tail-call targets —
  same argument-evaluation-order, same destructuring, same decision-tree compilation
  (`Optimize.Case`) as the unfused path.
- The parameter-sharing argument above is a safety proof about JS variable slots, not an
  approximation — no case exists where a stale value from a different member's prior iteration
  could be read, because every entry into a case fully overwrites that member's own parameter set
  first.
- Confirmation via a second `stronglyConnComp` pass (step 5) means a cluster is only ever packaged
  as fused if its members' *actual* generated code cross-tail-calls each other — an optimistic
  syntactic overshoot in step 2/3 can never produce an incorrectly-fused result, only, at worst, a
  missed (safe) fusion opportunity (same guarantee pattern as [[array-chain-fusion-spike]]'s
  `peelArrayStage`/`peelListStage`: unrecognized or disqualified shapes fall through to unmodified
  existing codegen, never wrong output).

## Testing / verification plan

No automated test suite exists in this repo (manual verification only, per CLAUDE.md). Scratch
`.elm` projects (Docker build per CLAUDE.md's build recipe) covering, at minimum:

- The original 2-member benchmark shape (`stepA`/`stepB`, shared arg names) — checksum-compared
  against pre-fusion output, both Dev and `--optimize`, plus the stack-depth robustness check
  (N large enough that the unfused compiler build would crash, confirming the fused build doesn't).
- A 3+-member ring (A→B→C→A) to exercise the general-N path specifically.
- A cluster where one member has an argument name no other member shares (exercises wrapper
  `undefined`-padding).
- A member with TRMC identity sitting in the same `Can.DeclareRec` group as an otherwise-fusable
  pair — confirms it's excluded from fusion and keeps its solo TRMC codegen unchanged.
- A one-way tail chain (A tail-calls B, B never calls back) — confirms it stays unfused
  (`AcyclicSCC`), unchanged `Opt.Call` output.
- A member that both tail-calls a sibling and tail-calls itself directly — confirms the "no special
  case for self vs. cross" codegen claim.
- Diff Dev-mode output for an unrelated, already-existing self-recursive function before/after this
  change, to confirm zero output change for code this plan doesn't touch (regression guard for the
  Dev/Prod-invariance claim).
