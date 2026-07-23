# Tuple Closed-Shape Compare — Design Spec

**Status:** ready for implementation
**Origin:** [[tuple-compare-closed-shape-spike]] (2026-07-23), POSITIVE: 1.31x-2.66x (micro), 1.38x-1.80x
(sort). Sibling to [[closed-type-structural-equality-plan]], for `compare`/`<`/`<=`/`>`/`>=`/`min`/`max`
instead of `==`/`/=`.

## Problem

`compare`, `<`, `<=`, `>`, `>=`, `min`, `max` are constrained to Elm's `comparable` type class: `Int`,
`Float`, `Char`, `String`, and `Tuple`/`List` of `comparable`. (Records and custom Unions are **not**
`comparable` at all — an earlier framing of this work as "extend `EqClosed` to Record/Union comparison"
was invalid and is dropped; see the spike memory for that correction.)

[[prim-binop-specialization-plan]] already specializes the flat-scalar case (`Int`/`Float`/`String`,
i.e. `Type.PrimType`) to raw JS operators. What it does **not** cover is `Tuple2`/`Tuple3` whose
components are themselves provably-scalar (e.g. `compare (p.priority, p.name) (q.priority, q.name)`, a
common `sortBy`/`sortWith` key pattern). Those calls still go through the generic kernel path: `_Utils_cmp`
(recursive walk over `.a`/`.b`/`.c`) wrapped in `_Utils_lt`/`_Utils_le`/`_Utils_gt`/`_Utils_ge`/
`_Utils_compare`/`_Utils_min`, each an `F2`-curried dispatch (`Elm.Kernel.Utils`).

## Scope (MVP)

**Closed-cmp shape**: a `Variable` resolves (Prod-mode only, same Dev/Prod contract as every prior plan
in this fork — see CLAUDE.md) to a `Tuple2`/`Tuple3` where every slot is *either*:
- a leaf whose type is a proven `Type.PrimType` (`PInt`/`PFloat`/`PStr`, plus **new** `PChar` — Char's
  canonical type is `AppN ModuleName.char "Char" []`, and it is already a raw JS string at runtime
  (`_Utils_chr__PROD`), so it slots into the existing `PrimType` machinery with no separate runtime
  representation concern), or
- itself a closed-cmp Tuple2/Tuple3 (recursive — this is the "nested tuples" scope decision), unbounded
  depth.

`List`-of-`comparable` call sites are explicitly unaffected: the compared type at the call site must
itself be `Tuple2`/`Tuple3` (or a bare `PrimType`, already handled). A `List` operand never resolves to
a closed-cmp shape (variable length, nothing to unroll), so `compare`/`<` on lists keeps calling the
generic kernel path exactly as today — including when the list's *elements* are closed tuples; that
per-element win is future work, not attempted here (the kernel's own `WHILE_CONSES` loop over `_Utils_cmp`
is not a call site the compiler ever sees).

A tuple slot that is a Record, Union, or another `List`/`Dict`/`Array` makes the *whole* comparison
ineligible (falls back to the generic path) — flat/nested-tuple-of-scalars only, matching the
flat-fields-only precedent in [[closed-type-structural-equality-plan]].

Gated on `isCheap` for both operands (same helper `compare`/`min`/`max` inlining already uses) — the
inlined form reads each operand's leaves once, but `min`/`max` additionally return one of the two
operands verbatim, so a non-cheap operand keeps the generic call.

## Mechanism

**Type-level probe.** `<`/`<=`/`>`/`>=` already emit a `CProbe` via `primOpProbe`, and `compare`/`min`/`max`
via `primCallProbe` (`Type.Constrain.Expression.hs:207,215,279,287`) — the same probe list `EqClosed`
resolves against. No new `Constraint` variant needed. A new `Type.toClosedCmpShape :: Variable -> IO
(Maybe CmpShape)` walks the unification `Structure`: `Tuple1 a b Nothing` / `Tuple1 a b (Just c)`
(`Type.Type.hs:95`) recursively, bailing to `Nothing` on any slot that isn't itself a `Tuple1` or a
`toPrimType` hit. Unlike the Union-eq probe, this needs **no module/home threading** — tuples aren't
module-owned, so `Type.Solve.run`'s signature only grows a return-tuple element (`resolveCmpProbes`), no
new parameters.

**New `Opt.Expr` node**, producing the -1/0/1 ordinal in one pass (the same shape `_Utils_cmp` computes,
inlined):

```haskell
data CmpShape
  = CmpLeaf
  | CmpTuple2 CmpShape CmpShape
  | CmpTuple3 CmpShape CmpShape CmpShape

CmpClosed CmpShape Expr Expr   -- new Expr constructor; evaluates to an Int -1/0/1
```

**Why an ordinal, not four separate bool-chains + a doubled compare:** the existing scalar
`makePrimCall` (`Optimize/Expression.hs:481-498`) builds `compare`/`min`/`max` from *two independent*
`PrimLt`/`PrimEq` comparisons (cheap for scalars — two raw ops). Reusing that shape for tuples would
walk the lexicographic structure **twice** per `compare` call — exactly the redundant work this feature
exists to remove. Instead:

- `toClosedCmpTarget` (mirrors `toClosedEqTarget`) checks a new `_cmpHints` map (keyed by region, added
  to `Optimize.Expression`'s `Hints`) for `<`/`<=`/`>`/`>=` operator sites and `compare`/`min`/`max` call
  sites.
- **Operators** rewrite to the *existing* `PrimLt`/`PrimLe`/`PrimGt`/`PrimGe` `Opt.PrimOp` codegen cases
  (`Generate/JavaScript/Expression.hs:920-923`, unchanged) with the ordinal as the left operand and
  `Opt.Int 0` as the right — no new operator codegen needed, `PrimLe` already means `<= 0` (matches the
  kernel's `_Utils_le = cmp < 1`, since the ordinal is always exactly one of {-1,0,1}).
- **`compare`/`min`/`max`** hoist the ordinal into a fresh local via `Opt.Let (Opt.Def tmp (CmpClosed
  shape left right)) body`, using `Names.generate` (the same fresh-name mechanism
  [[cross-container-conversion-fusion-plan]]'s `buildFusedCrossFold` already uses, e.g.
  `Optimize/Expression.hs:1298,1306`), then branch on `VarLocal tmp` the same way `makePrimCall` already
  branches on `PrimLt`/`PrimGt`/`PrimEq` today — one ordinal computation, three ways to read it.

**Codegen** (`Generate/JavaScript/Expression.hs`): `generateClosedCmp` mirrors `generateClosedEq`'s
Dev/Prod split. **Dev** ignores the shape, reproduces the exact prior `_Utils_lt`/`_Utils_le`/
`_Utils_gt`/`_Utils_ge`/`_Utils_compare`/`_Utils_min` call (byte-identical Dev output — CLAUDE.md's
Mode.Dev contract), but the node still declares the `Elm.Kernel.Utils` dependency and the original
`Basics.<op>` global edge, for the same DCE-reachability reason `registerClosedEq` documents. **Prod**
recursively lowers `CmpShape` into a nested-ternary JS expression computing the ordinal directly
(`x.a !== y.a ? (x.a < y.a ? -1 : 1) : <recurse into next slot>`, descending through `.a`/`.b`/`.c` for
nested tuples) — structurally identical to the spike's `ucmp` functions.

## Files touched

| File | Change |
|---|---|
| `compiler/src/Type/Type.hs` | `PChar` added to `PrimType` + `toPrimType` Char case; `toClosedCmpShape` |
| `compiler/src/Type/Solve.hs` | `run` gains one more resolve pass (`resolveCmpProbes`) + one more return-tuple element — no new params |
| `compiler/src/Compile.hs` | thread the new hints map through `typeCheck`/`optimize` |
| `compiler/src/AST/Optimized.hs` | `CmpClosed`/`CmpShape` + `Binary` instances (new tag) |
| `compiler/src/Nitpick/Debug.hs` | exhaustiveness arm |
| `compiler/src/Generate/Mode.hs` | exhaustiveness arm (`scan`, single-callback-use analysis) |
| `compiler/src/Nitpick/WorkerRegistry.hs` | exhaustiveness arm (`exprTargets`) |
| `compiler/src/Generate/JavaScript/Expression.hs` | `generateClosedCmp` + dispatch arm |
| `compiler/src/Optimize/Module.hs` | `Hints` construction gains 1 arg (`_cmpHints`) |
| `compiler/src/Optimize/Expression.hs` | `Hints` record + `toClosedCmpTarget`; operator rewrite; `makePrimCall`'s closed-shape branch (`Opt.Let`-hoisted ordinal) |

## Explicitly out of scope (future work, not this pass)

- `List`-of-`comparable` call sites, including when list elements are closed tuples (see Scope above).
- A tuple slot that is itself a closed Record/Union (this pass is tuple-of-{scalar,tuple} only; a
  Record/Union slot falls back to the generic path even though `EqClosed` can already prove that shape
  for `==` — unifying the two probes is a natural follow-up once this lands, not part of this MVP).
- `Tuple0` (`()`) — not `comparable`, no `CProbe` ever targets it; nothing to do.

## Verification plan

Same discipline as every prior plan in this fork (see CLAUDE.md — no automated test suite): real Docker
`cabal build`, Dev vs. `--optimize` output diffed for the same source (Dev must be byte-identical to
before), explicit negative cases (row-polymorphic/generic tuple slot via a type variable, `List`-typed
compare, Record/Union tuple slot, mixed with an ineligible slot) confirmed to still take the generic
`_Utils_*` path. Performance confirmed via a two-binary (before/after) benchmark mirroring the spike's
fixture (sortWith over tuple keys, flat/nested/Char shapes), with fresh `ELM_HOME`/`elm-stuff` per binary
per [[elm-stuff-cache-contamination-finding]]'s discipline.
