# Tuple Closed-Shape Compare — Design Spec

**Status:** ready for implementation (revised after two corrections found while drafting the
implementation plan — see "Corrections" below)
**Origin:** [[tuple-compare-closed-shape-spike]] (2026-07-23), POSITIVE after correction: 1.41x-2.19x
(operators, micro), 1.41x-2.53x (`compare`/`min`/`max`, micro), 1.25x-1.82x (sort). Sibling to
[[closed-type-structural-equality-plan]], for `compare`/`<`/`<=`/`>`/`>=`/`min`/`max` instead of `==`/`/=`.

## Problem

`compare`, `<`, `<=`, `>`, `>=`, `min`, `max` are constrained to Elm's `comparable` type class: `Int`,
`Float`, `Char`, `String`, and `Tuple`/`List` of `comparable`. (Records and custom Unions are **not**
`comparable` at all — an earlier framing of this work as "extend `EqClosed` to Record/Union comparison"
was invalid and is dropped; see the spike memory for that correction.)

[[prim-binop-specialization-plan]] already specializes the flat-scalar case (`Int`/`Float`/`String`,
i.e. `Type.PrimType`) to raw JS operators. What it does **not** cover is `Tuple2`/`Tuple3` whose
components are themselves provably-scalar (e.g. `compare (p.priority, p.name) (q.priority, q.name)`, a
common `sortBy`/`sortWith` key pattern).

**What the generic path actually costs today (corrected — see below):** for `<`/`<=`/`>`/`>=`, a single
raw call to the kernel's `_Utils_cmp` (recursive walk over `.a`/`.b`/`.c`, `typeof`-branching), no
`F2`/`A2` dispatch. For `compare`, a real `F2`/`A2` dispatch into `Elm.Kernel.Utils.compare` (a direct
kernel re-export), which itself calls `_Utils_cmp`. For `min`/`max`, a real `A2` dispatch into their own
compiled Elm bodies (`elm/core`'s `min x y = if lt x y then x else y`), which internally *also* reduce to
a single `_Utils_cmp` call (see Corrections).

## Corrections found while drafting the implementation plan

Both matter enough to record here so the plan doesn't re-derive them.

**1. The generic baseline is not uniform across operators.** `Generate/JavaScript/Expression.hs`'s
`generateBasicsCall` already special-cases `Basics.lt`/`gt`/`le`/`ge` (and `eq`/`neq`) *structurally* —
regardless of any Optimize-phase hint — into the existing `cmp`/`equal` helpers, which for two
non-literal operands emit a raw `_Utils_cmp(a,b) OP N` call with **no `F2`/`A2` wrapper**. Only `compare`
(a literal `Elm.Kernel.Utils.compare` re-export) and `min`/`max` (plain Elm functions, but reached via a
real `A2` call into their own compiled body) go through actual `F2`/`A2` dispatch today. The initial spike
modeled every operator's baseline as `A2`-dispatched; a corrected spike (`bench2.js`, same shapes)
confirmed the feature is still positive with the accurate baseline, just smaller for the four operators:
1.41x-2.19x rather than the original 1.31x-2.66x. `compare`/`min`/`max` came out close to the original
estimate (1.41x-2.53x), since their real baseline does include `A2`.

**2. Byte-identical Dev output rules out the originally-planned single-ordinal-node design.** The first
draft of this spec proposed one opaque node (`CmpClosed`, producing a -1/0/1 ordinal) with `<`/`<=`/`>`/
`>=` composed on top via the *existing* `Opt.PrimOp PrimLt/PrimLe/PrimGt/PrimGe` against a literal `0`,
and `compare`/`min`/`max` composed via a generic `Opt.Let`+`Opt.If` at the `Optimize.Expression` AST
level. Both compositions turn out to change Dev output:
- `cmp`'s *existing* backup comparison for `<=`/`>=` is `< 1` / `> -1`, not `<= 0` / `>= 0` — composing
  via `PrimLe`/`PrimGe` against `0` would have emitted different (if semantically equivalent) JS bytes.
- `Optimize.Expression` builds one `Opt.LocalGraph` per module that serves **both** Dev and Prod codegen
  (Mode is a Generate-phase concept — see CLAUDE.md's Mode.Dev/Mode.Prod section). A generic `Let`/`If`
  decomposition built at that layer is mode-*agnostic*: Dev's ordinary `Let`/`If` codegen would render it
  plainly, which is a different JS shape than today's single `A2(_Utils_compare, a, b)` call — breaking
  the byte-identical-Dev-output contract even though nothing about *this specific* rewrite was meant to
  touch Dev.

The fix (below) keeps every Dev/Prod split inside a small number of new, opaque `Opt.Expr` nodes whose own
codegen function is the only place Mode is consulted — the same discipline `EqClosed` already established
— rather than decomposing into generic `Let`/`If` at the optimize layer.

## Scope (MVP)

**Closed-cmp shape**: a `Variable` resolves to a `Tuple2`/`Tuple3` where every slot is *either*:
- a leaf whose type is `Int`, `Float`, `String`, or `Char` (see "Char handling" below — deliberately
  **not** implemented by extending `Type.PrimType`), or
- itself a closed-cmp Tuple2/Tuple3 (recursive — the "nested tuples" scope decision), unbounded depth.

**Char handling.** Char is **not** added to the shared `Type.PrimType`. `Type.PrimType` feeds
`toPrimBinop`'s raw `===`/`<` scalar codegen (`Opt.PrimOp`), which is **not** Mode-gated — it applies in
Dev and Prod alike (`generatePrimOp` has no `Mode.Dev`/`Mode.Prod` case split at all). Char is boxed in
`--debug`/Dev mode (`_Utils_chr__DEBUG(c) { return new String(c); }`), so a raw `===` on two Chars would
silently break Dev-mode Char equality if Char were added there (`new String('a') === new String('a')` is
`false`). This feature's own codegen is Prod-mode-only (see Mechanism), so Char is safe *here* in a way it
is not for the shared `PrimType` — recognized via a small standalone `Type.isCmpLeafType` probe (Int,
Float, String, Char), entirely separate from `toPrimType`/`PrimType`, never touching the existing scalar
machinery.

`List`-of-`comparable` call sites are explicitly unaffected: the compared type at the call site must
itself be `Tuple2`/`Tuple3` (or a bare `PrimType`, already handled). A tuple slot that is a Record, Union,
or `List`/`Dict`/`Array` makes the *whole* comparison ineligible (falls back to the generic path) —
flat/nested-tuple-of-scalars only, matching the flat-fields-only precedent in
[[closed-type-structural-equality-plan]].

Gated on `isCheap` for both operands (same helper `compare`/`min`/`max` inlining already uses).

## Mechanism

**Type-level probe.** `<`/`<=`/`>`/`>=` already emit a `CProbe` via `primOpProbe`, and `compare`/`min`/`max`
via `primCallProbe` (`Type.Constrain.Expression.hs:207,215,279,287`) — the same probe list `EqClosed`
resolves against. No new `Constraint` variant needed. A new `Type.toClosedCmpShape :: Variable -> IO
(Maybe Type.CmpShape)` walks the unification `Structure`: `Tuple1 a b Nothing` / `Tuple1 a b (Just c)`
(`Type.Type.hs:95`) recursively, with each slot resolved by `Type.isCmpLeafType` (leaf) or recursively by
itself (nested tuple). No module/home threading needed — tuples aren't module-owned, so `Type.Solve.run`'s
signature only grows a return-tuple element, no new parameters.

`Type.CmpShape` (defined in `Type/Type.hs`, since the probe lives there) and `Opt.CmpShape` (defined in
`AST/Optimized.hs`, structurally identical, used by the two new `Opt.Expr` nodes below) are **separate**
types, translated by a small `toOptCmpShape :: Type.CmpShape -> Opt.CmpShape` in `Optimize.Expression`
(which already imports both modules). This mirrors the existing layering: `AST.Optimized` never imports
`Type.Type` (a type-checker-internal module), exactly as `ClosedEqShape` was kept self-contained rather
than reusing anything from `Type.Type`.

**Two new opaque `Opt.Expr` nodes**, each fully deciding its own Dev/Prod codegen (no generic AST
decomposition at the Optimize layer — see Correction 2):

```haskell
data CmpShape
  = CmpLeaf
  | CmpTuple2 CmpShape CmpShape
  | CmpTuple3 CmpShape CmpShape CmpShape

data CmpOp = OpLt | OpLe | OpGt | OpGe

data CmpCallKind
  = KCompare Expr Expr Expr   -- registered LT, EQ, GT ctor refs (Names.registerCtor, at optimize time)
  | KMin
  | KMax

CmpOpClosed   CmpOp CmpShape Expr Expr    -- new Expr constructor; Bool. For `<`/`<=`/`>`/`>=`.
CmpCallClosed CmpShape Expr Expr CmpCallKind
  -- new Expr constructor; Order (KCompare) or same type as operands (KMin/KMax).
  -- For `compare`/`min`/`max`.
```

- `toClosedCmpTarget` (mirrors `toClosedEqTarget`) checks a new `_cmpHints :: Map A.Region Opt.CmpShape`
  map (added to `Optimize.Expression`'s `Hints`, populated from `Type.Solve`'s new resolve pass via
  `toOptCmpShape`) for `<`/`<=`/`>`/`>=` operator sites (`Can.Binop`'s existing `Nothing` branch, alongside
  the existing `toClosedEqTarget` check) and `compare`/`min`/`max` call sites (`toPrimCall`'s existing
  `Nothing` branch from `_primHints`).
- Both operands must be `isCheap`; `KCompare`'s LT/EQ/GT ctor refs are obtained via the same
  `Names.registerCtor ModuleName.basics "LT"/"EQ"/"GT" Index.first/second/third Can.Enum` calls the
  existing scalar `CallCompare` already makes.

**Codegen** (`Generate/JavaScript/Expression.hs`):

- `generateCmpOpClosed` (for `CmpOpClosed`): **Dev** calls the *existing* `cmp` helper unchanged, with the
  exact `(idealOp, backupOp, backupInt)` triple `generateBasicsCall` already uses per operator (`OpLt ->
  cmp JS.OpLt JS.OpLt 0`, `OpLe -> cmp JS.OpLe JS.OpLt 1`, `OpGt -> cmp JS.OpGt JS.OpGt 0`, `OpGe -> cmp
  JS.OpGe JS.OpGt (-1)`) — byte-identical to today's output, since `cmp`'s `isLiteral` fast path can never
  fire for a Tuple-typed operand (Tuples are always JS object literals, never `JS.String`/`Float`/`Int`/
  `Bool`). **Prod** recursively lowers `CmpShape` into a direct short-circuiting boolean chain per operator
  (no intermediate ordinal — e.g. for `OpLt`: `x.a !== y.a ? x.a < y.a : x.b < y.b`, descending through
  `.a`/`.b`/`.c` for nested tuples) — structurally identical to the corrected spike's `ult`/`ule`/`ugt`/
  `uge` functions.
- `generateCmpCallClosed` (for `CmpCallClosed`): **Dev** calls the *existing* `generateGlobalCall`
  unchanged, with the original Basics function name (`"compare"`/`"min"`/`"max"`) — byte-identical to
  today's `A2(global, left, right)`. **Prod**: for `KMin`/`KMax`, a single ternary using a direct
  short-circuit boolean condition (like the operator case) with `left`/`right` as the two branches — no
  intermediate value, matching the spike's `umin`/`umax`. For `KCompare`, the ordinal must be read three
  ways (LT/EQ/GT), so it genuinely needs to be computed once and reused; this is done by constructing a
  small `Opt.Let (Opt.Def tmp ordinalExpr) (Opt.If [...] ...)` **locally inside this codegen function only**
  (not stored in `.elmo`, not visible to any other pass) and recursing into it via the already-existing
  `generateJsExpr` — reusing already-working `Let`/`If` codegen for the "compute once, branch three ways"
  shape without that decomposition ever being visible to Dev-mode codegen (which never reaches this branch
  of `generateCmpCallClosed` at all).

## Files touched

| File | Change |
|---|---|
| `compiler/src/Type/Type.hs` | `CmpShape`, `isCmpLeafType`, `toClosedCmpShape` (no `PrimType` change) |
| `compiler/src/Type/Solve.hs` | `run` gains one more resolve pass (`resolveCmpProbes`) + one more return-tuple element — no new params |
| `compiler/src/Compile.hs` | thread the new hints map through `typeCheck`/`optimize` |
| `compiler/src/AST/Optimized.hs` | `CmpOpClosed`/`CmpCallClosed`/`CmpShape`/`CmpOp`/`CmpCallKind` + `Binary` instances (2 new `Expr` tags) |
| `compiler/src/Nitpick/Debug.hs` | 2 exhaustiveness arms |
| `compiler/src/Generate/Mode.hs` | 2 exhaustiveness arms (`scan`, single-callback-use analysis) |
| `compiler/src/Nitpick/WorkerRegistry.hs` | 2 exhaustiveness arms (`exprTargets`) |
| `compiler/src/Generate/JavaScript/Expression.hs` | `generateCmpOpClosed`, `generateCmpCallClosed` + 2 dispatch arms |
| `compiler/src/Optimize/Module.hs` | `Hints` construction gains 1 arg (`_cmpHints`) |
| `compiler/src/Optimize/Expression.hs` | `Hints` record + `toClosedCmpTarget`/`toOptCmpShape`; operator rewrite in `Can.Binop`; `toPrimCall`/`makePrimCall`'s closed-shape branch |

## Explicitly out of scope (future work, not this pass)

- `List`-of-`comparable` call sites, including when list elements are closed tuples.
- A tuple slot that is itself a closed Record/Union (tuple-of-{scalar,tuple} only this pass; unifying with
  `EqClosed`'s record/union probe is a natural follow-up, not part of this MVP).
- `Tuple0` (`()`) — not `comparable`, no `CProbe` ever targets it; nothing to do.

## Verification plan

Same discipline as every prior plan in this fork (see CLAUDE.md — no automated test suite): real Docker
`cabal build`, Dev vs. `--optimize` output diffed for the same source (Dev must be byte-identical to
before — this is the sharpest test of Correction 2 above), explicit negative cases (row-polymorphic/
generic tuple slot via a type variable, `List`-typed compare, Record/Union tuple slot, mixed with an
ineligible slot) confirmed to still take the generic path. Performance confirmed via a two-binary
(before/after) benchmark mirroring the corrected spike's fixture (sortWith over tuple keys, flat/nested/
Char shapes), with fresh `ELM_HOME`/`elm-stuff` per binary per
[[elm-stuff-cache-contamination-finding]]'s discipline.
