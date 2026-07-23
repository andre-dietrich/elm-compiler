# Closed-Type Structural Equality — Design Spec

**Status:** ready for implementation
**Origin:** [[closed-type-structural-equality-spike]] (2026-07-21 optimization research sweep), POSITIVE, 2.0x-3.3x on closed Record/Union `==`/`/=`.

## Problem

`==`/`/=` on a Record or custom-type (Union) value always compiles to a call into the generic kernel
`_Utils_eq`/`_Utils_neq`, which walks both operands with a `for...in` loop and recurses per key
(`_Utils_eqHelp` in `Elm.Kernel.Utils`). This is true even when the type checker can prove, at the
`==`/`/=` call site, that both operands have a **closed** (non-row-polymorphic) shape whose every
field is already a JS-primitive-safe scalar (Int/Float/Bool/String) — in that case the dynamic walk is
pure overhead: a fixed, statically known sequence of `===` comparisons would do.

This mirrors two mechanisms already shipped in this fork:
- [[prim-binop-specialization-plan]] — proves a **scalar** `==` site is Int/Float/Bool/String-typed,
  emits raw `===` instead of `_Utils_eq`.
- [[static-shape-record-clone-plan]] — proves a **record update** site's shape is closed, emits a
  static object literal instead of `Object.assign`.

This feature is the same "keyed→named access" win one level up: proving a **record's or union's**
`==`/`/=` operands are closed and flat (no nested container/record/union fields), so the whole
comparison can be unrolled into named `===` reads instead of `_Utils_eq`'s dynamic walk.

## Scope (MVP)

Two independent shapes are covered, both **Prod-mode only** (Dev output must stay byte-identical —
see CLAUDE.md's Mode.Dev/Mode.Prod contract):

1. **Closed Record**: the record type is closed (its extension bottoms out at `EmptyRecord1`, same
   proof `Type.toClosedFields` already uses) AND every field's own type resolves to one of the four
   known `PrimType`s (Int/Float/Bool/String). A field that is itself a nested Record/Union/List/Dict/
   Array/Tuple/Maybe/etc. makes the whole record ineligible (falls back to generic `_Utils_eq`) — this
   is a flat-fields-only first pass, no recursion into nested closed shapes.

2. **Closed Union**: the compared type is `App1 home name []` where:
   - `home` is the module **currently being compiled** (cross-module union lookups aren't attempted —
     `Can.Module._unions` only has definitions local to the module being type-checked; extending this
     to imported unions would need the exporting module's `Elm.Interface`, which `Type.Solve` doesn't
     currently receive, and is out of scope for this pass).
   - the union has **no type parameters** (`_u_vars == []`) — avoids needing the ctor-arg-type
     substitution machinery a generic union's instantiation would require.
   - `_u_opts == Can.Normal` — explicitly excludes `Can.Enum` (raw JS integers at runtime in Prod, no
     `$`/`aN` object fields to read at all — `.{$,a1..}` access on a number is a distinct, separately
     valuable optimization, **not** attempted here, see Future Work) and `Can.Unbox` (identity-erased
     newtype; the runtime value literally **is** the unwrapped payload, not an object either).
   - every ctor's every argument type resolves (via a static, non-substituting `Can.Type` walk — safe
     specifically because the union is non-generic, so no ctor argument type can mention a type
     variable) to one of the four known `PrimType`s.

   The proof yields the union's max ctor arity (`maxArity`, same `max over ctor arg counts` formula
   `Optimize.Module.addUnion` already computes for Prod's ctor-shape-padding). Every Prod-mode variant
   of a `Can.Normal` union already shares one padded object shape (`{$, a1..a<maxArity>}`, see
   [[adt-shape-padding-plan]]), so after confirming `left.$ === right.$` (same ctor, hence same real
   arity), the remaining `a1..a<maxArity>` slots can be compared unconditionally: real payload slots on
   both sides hold real prim values, and any padding slots beyond that ctor's real arity hold `null` on
   *both* sides — `null === null` is trivially true, so no per-ctor branch is needed at all.

Both shapes are additionally gated on `isCheap` for both operands (same helper the compare/min/max
inlining in [[prim-binop-specialization-plan]] uses): the flat comparison references each operand
multiple times (once per field/slot), so it's only safe to skip a `Let`-binding when re-reading the
operand is free (`VarLocal`/`VarGlobal`/`VarEnum`/literal/`Access` chain). A non-cheap operand keeps
the generic `Basics.eq`/`neq` call — no new machinery for temp-binding, matching how compare/min/max
already handles this.

## Mechanism

Reuses the **existing** `CProbe A.Region Variable Variable` constraint that `constrainBinop` already
emits for `==`/`/=`/`<`/`>`/`<=`/`>=`/`++` (see `Type.Constrain.Expression.primOpProbe`) — no new
`Constraint` variant needed. `Type.Solve.run` already resolves this list of probes once into
`_primHints` (`Type.toPrimType`); this feature adds two more resolution passes over the *same* probe
list:

- `resolveRecordEqProbes` via a new `Type.toClosedPrimFields :: Variable -> IO (Maybe (Set Name))`
  (structurally: `toClosedFields` + `toPrimType` on every field, bail to `Nothing` on any non-prim
  field).
- `resolveUnionEqProbes` via a new
  `Type.toClosedUnionEqArity :: ModuleName.Canonical -> Map Name Can.Union -> Variable -> IO (Maybe Int)`,
  needing the current module's name and `Can.Module._unions` map threaded into `Type.Solve.run` (new
  parameters — the only signature change to the solver's entry point).

`Optimize.Expression`'s `Hints` record gains two more fields (`_recordEqHints`, `_unionEqHints`),
populated the same way `_primHints`/`_recordShapeHints` already are. `Can.Binop` for `"eq"`/`"neq"`
checks these hints (after the existing scalar `_primHints` check, which still wins for e.g.
`Int == Int`) and, when a hint is present and both operands are cheap, rewrites to a **new**
`AST.Optimized` node:

```haskell
data ClosedEqShape
  = ClosedEqRecord (Set.Set Name)   -- field names, all proven prim
  | ClosedEqUnion Int                -- maxArity

  | EqClosed Bool ClosedEqShape Expr Expr   -- new Expr constructor; Bool = True for "==", False for "/="
```

This is a genuine `.elmo`/`.elmi` **wire-format change** (new `Expr` constructor, new Binary tag 30) —
per CLAUDE.md, every cached `.elmo`/`.elmi` (project `elm-stuff/` and `ELM_HOME` package caches) becomes
unreadable until deleted; verification must account for this (fresh `ELM_HOME`/`elm-stuff` per binary,
same discipline as [[adt-shape-padding-plan]] and [[static-shape-record-clone-plan]]).

`Generate.JavaScript.Expression` gets a new `generateClosedEq` case: `Mode.Dev` ignores the shape and
reproduces the exact prior `_Utils_eq`/`_Utils_neq` call (so Dev output is unaffected — but the *node*
must still declare a Kernel dependency on `Elm.Kernel.Utils`, since skipping `Names.registerGlobal
ModuleName.basics "eq"` at the call site would otherwise let dead-code elimination drop the Utils
kernel chunk in a program that uses no *other* path to `_Utils_eq`, breaking the Dev-mode fallback this
same node still needs — see Task 4 below). `Mode.Prod` emits the flat `&&`-chain of `===` reads
described above, negated with a leading `!` for `/=`.

## Files touched

| File | Change |
|---|---|
| `compiler/src/Type/Type.hs` | `toClosedPrimFields`, `toClosedUnionEqArity`, `closedPrimOfCanType` |
| `compiler/src/Type/Solve.hs` | `run` gains `ModuleName.Canonical` + `Map Name Can.Union` params, 2 more resolve passes, 2 more return-tuple elements |
| `compiler/src/Compile.hs` | thread the 2 new maps through `typeCheck`/`optimize` |
| `compiler/src/AST/Optimized.hs` | `EqClosed`/`ClosedEqShape` + `Binary` instances (tag 30) |
| `compiler/src/Nitpick/Debug.hs` | exhaustiveness arm |
| `compiler/src/Generate/Mode.hs` | exhaustiveness arm (`scan`, single-callback-use analysis) |
| `compiler/src/Nitpick/WorkerRegistry.hs` | exhaustiveness arm (`exprTargets`) |
| `compiler/src/Generate/JavaScript/Expression.hs` | `generateClosedEq` + dispatch arm |
| `compiler/src/Optimize/Module.hs` | `Hints` construction gains 2 args |
| `compiler/src/Optimize/Expression.hs` | `Hints` record + `Can.Binop` rewrite (`toClosedEqTarget`, `registerClosedEq`) |

## Explicitly out of scope (future work, not this pass)

- Cross-module closed unions (needs `Elm.Interface` ctor data threaded into `Type.Solve`).
- Generic (parameterized) closed unions, e.g. `Result String Int` (needs ctor-arg-type substitution).
- Nested closed shapes (a record field that is itself a closed record/union) — recursion is a natural
  follow-up once the flat case is shipped and measured on the real compiler.
- `Can.Enum` union `==` → raw `===` (Enum values are bare JS integers in Prod, not objects at all —
  a simpler, different mechanism, likely a small extension to `Type.toPrimType` itself rather than
  this record/union machinery; noted here so it isn't lost, not part of this plan).

## Verification plan

Same discipline as prior plans in this fork: no automated test suite exists (see CLAUDE.md), so
correctness is a real Docker `cabal build` + scratch Elm project compiled in both Dev and `--optimize`,
JS output inspected, executed under Node with checksums, and explicit negative cases (row-polymorphic
record arg, cross-module union, generic union, nested-record field, `List`/`Dict` field, Enum/Unbox
ctor opts) confirmed to still take the generic `_Utils_eq` path. Performance is confirmed via a
two-binary (before/after) benchmark mirroring the spike's fixture, per
[[elm-stuff-cache-contamination-finding]]'s discipline (fresh `ELM_HOME`/`elm-stuff` per binary, never
compiled in the same project directory).
