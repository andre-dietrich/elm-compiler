# Design Spec: Function-Composition (`<<`/`>>`) Chain Flattening

## Motivation

Follow-up to the 2026-07-24 optimization research sweep ([[optimization-research-sweep-2-summary]]):
two independent research tracks converged on the same finding. `f << g` (and `f >> g`) compile through
the fully generic curried-call path — `Basics.composeL`/`composeR` are ordinary two-argument Elm
functions (`composeL g f x = g (f x)`), so a chain `f << g << h` builds nested partial applications at
runtime rather than one flat closure. Hand-written Node microbenchmarks reproducing the current-vs-
flattened JS pattern measured 3.6x-3.9x (4-function chain, steady state) and 2.1x-5.4x (scaling with
chain length 2-16), from two independently-run tracks.

This optimization existed once already: `decomposeL`/`decomposeR` in `Generate/JavaScript/Expression.hs`,
removed upstream in commit `6ae01688` ("Stop doing special things for (<<) and (>>)", fixing
[elm/compiler#1722](https://github.com/elm/compiler/issues/1722)). Fetching that issue directly
(`gh api repos/elm/compiler/issues/1722`) gives the exact failing input:

```elm
fromMaybe f =
    f << (<<) Just
```

which the 2018 codegen turned into:

```javascript
var fromMaybe = function (f) {
    return function ($) {
        return f(
            function ($) {
                return elm$core$Maybe$Just(
                    $($));
            });
    };
};
```

Note the inner `$($)` — a variable applied to itself, discarding the real captured argument entirely.
This design's job is to re-add the optimization while structurally ruling out that bug class, not just
patching the symptom.

## Root cause of the historical bug (traced against this repo's current code, not just the issue text)

The 2018 `decomposeL`/`decomposeR` built their flattened body via the *existing*, still-present `apply`
helper (`Generate/JavaScript/Expression.hs:858-863`):

```haskell
apply :: Opt.Expr -> Opt.Expr -> Opt.Expr
apply func value =
  case func of
    Opt.Accessor field -> Opt.Access value field
    Opt.Call f args    -> Opt.Call f (args ++ [value])
    _                  -> Opt.Call func [value]
```

`apply`'s middle case is a general "extend a curried call's argument list" trick, also used unchanged
today by `apL`/`apR` (`<|`/`|>`, `Expression.hs:792-793`). It is exactly what breaks composition
flattening: `(<<) Just` is, at the `Opt.Expr` level, a *partial* call `Opt.Call composeL [Just]` (one of
`composeL`'s two arguments). `decomposeL`'s old fallback called `apply ((<<) Just) (VarLocal "$")`,
which — because `func` here already is an `Opt.Call` — matched the middle case and **resaturated** it
into `Opt.Call composeL [Just, VarLocal "$"]`, a *newly complete* two-argument `composeL` call built
from the outer flattening's own bound variable.

That resaturated call is then compiled independently (any 2-arg call to `composeL` routes back through
`generateBasicsCall`'s `"composeL" -> decomposeL ...` dispatch, regardless of where it appears), which
recurses into `decomposeL` *again* and mints *another* `Opt.Function [N.dollar] ...` wrapper — reusing
the same hardcoded literal name `"$"` (`JsName.dollar`, `Name.hs:178-180`) that the *outer* flattening
also used for its own bound parameter. The inner function's own new `$` parameter then shadows the
outer `$` it was supposed to capture, producing the observed `$($)`.

Two consequences for this design, not one:

1. **A fixed/hardcoded binder name is unsafe** — any newly introduced parameter must be guaranteed
   distinct from every enclosing scope's own bindings.
2. **The danger is triggered specifically by reusing `apply`'s argument-extension trick on an
   under-saturated `composeL`/`composeR` operand.** A scope restriction alone (only recognizing already-
   saturated chain links) does not prevent this, because `apply` performs the resaturation
   *unconditionally*, regardless of what the caller intended. The fix has to avoid feeding an
   under-saturated `composeL`/`composeR` operand into the generic `apply` helper at all, not merely
   restrict which top-level shapes trigger flattening.

## Scope

**Trigger:** a `Basics.composeL`/`composeR` call with exactly 2 arguments (mirrors the existing dispatch
arm in `generateBasicsCall`'s `[elmLeft, elmRight] -> case name of ...`, `Expression.hs:787-790`, which
today has a comment noting the removal and nothing else).

**Chain collection walks both operand directions**, unlike the original (which only peeled the left
operand of `composeL`/right operand of `composeR`). `Basics.elm`'s fixity declarations make `<<`
right-associative and `>>` left-associative, so a natural unparenthesized chain nests on the *opposite*
side from what the original single-direction peel checked — walking both sides means a plain
`a << b << c << d` and an explicitly parenthesized `((a << b) << c) << d` both collect into the same
flat `[a, b, c, d]`, and it works correctly regardless of which associativity direction the source
happened to use.

**A chain link is only unfolded further if it is itself a *saturated* (exactly 2-argument)
`composeL`/`composeR` call.** Anything else — a plain function reference, a lambda, a call to some
other function, **and explicitly an under-saturated `composeL`/`composeR` operand like `(<<) Just`** —
is a terminal leaf. Terminal leaves are compiled via the ordinary, unmodified `generateJsExpr` and
combined into the chain with a **plain JS function call**, never through the generic `apply` helper's
argument-extension path. This is what rules out the historical bug by construction: the resaturation
step that caused it never happens, because compose-chain folding does not reuse `apply` at all.

**Not in scope:**
- Chains passed through an opaque value (e.g. a function parameter that happens to be a composition at
  some call site, but isn't visible as a literal `composeL`/`composeR` expression at the point being
  compiled) — same class of restriction as every existing fusion pass in this fork (List/Dict/Set/Array
  fusion all require the chain to be syntactically visible).
- Any change to how `(<<)`/`(>>)` compile when used as a bare, non-chained partial application (e.g.
  `List.foldr (<<) identity fns`) — those keep using today's unmodified generic codegen; this design
  does not touch that path at all.

## Mode

**`Mode.Prod` only**, matching every other perf-motivated codegen change in this fork (Prim-Binop
Specialization, ADT Shape Padding, Unwrapped-HOFs, TRMC, Record-Update inlining, etc. — see
[[build-setup]] and the fork's whole optimization history). Not because this specific rewrite is known
to be unsafe in `Mode.Dev` (nothing about it depends on any `Mode.Prod`-only table like
`shortenFieldNames`/`computeArities`), but for consistency with the project's established practice and
to keep `Mode.Dev` output — a contract for the debugger/time-travel tooling per `CLAUDE.md` — completely
unaffected by this change. No `.elmo`/binary-format impact: this only changes `Generate.JavaScript`
codegen, not `AST.Optimized`'s shape.

## Naming

Every newly introduced JS parameter uses a name in the same collision-free family as this fork's
existing TRMC scaffolding names (`makeMCStart`/`makeMCCell`/`makeMCHead`/`makeMCField`,
`Generate/JavaScript/Name.hs:143-175`, whose own comment states the invariant this design relies on:
*"`$` cannot appear in Elm identifiers, so these can never collide with argNames or user locals"*) —
a fixed name, e.g. `$compose$`, distinct from the bare `dollar`/`"$"` used elsewhere (record-update
temp, ctor tag field, generic partial-application currying) so that this rewrite's own bindings can
never be shadowed by, or shadow, anything from those unrelated codepaths.

**No per-invocation counter is needed, and a single fixed name is sufficient** — this falls out of the
leaf-combination strategy above, not out of a separate uniqueness mechanism bolted on afterwards. Every
terminal leaf is compiled independently (via the ordinary, unmodified `generateJsExpr`) and combined
into the chain with a plain JS call (`leaf(runningValue)`); the leaf's own internals — including any
*separate*, nested `composeL`/`composeR` expression the leaf happens to contain, which would trigger
this same rewrite recursively — are never textually spliced into or substituted through this rewrite's
own body the way the historical `apply`-based resaturation did. A nested invocation's closure is called
normally from outside, opaquely; it never needs to see through, or be seen through by, an enclosing
invocation's own parameter. Since no invocation of this rewrite ever needs to reference an *enclosing*
invocation's parameter, two invocations using the textually identical name `$compose$`, however deeply
nested relative to each other, cannot capture one another — the historical bug specifically required a
newly-introduced parameter to *shadow* a reference to an outer one that a nested closure still needed
to reach, which this design's leaf/chain-link boundary never creates.

## Where this lives

`Generate/JavaScript/Expression.hs`, replacing the current no-op comment at lines 789-790 inside
`generateBasicsCall`'s `[elmLeft, elmRight]` arm:

```haskell
[elmLeft, elmRight] ->
  case name of
    "composeL" ->
      case mode of
        Mode.Dev _    -> generateGlobalCall home name [generateJsExpr mode elmLeft, generateJsExpr mode elmRight]
        Mode.Prod _ _ -> flattenCompose mode Basics.composeL elmLeft elmRight

    "composeR" ->
      case mode of
        Mode.Dev _    -> generateGlobalCall home name [generateJsExpr mode elmLeft, generateJsExpr mode elmRight]
        Mode.Prod _ _ -> flattenCompose mode Basics.composeR elmLeft elmRight

    "append"   -> append mode elmLeft elmRight
    ...
```

(Matches the established `case mode of Mode.Dev _ -> ...; Mode.Prod _ _ -> ...` pattern already used
throughout this file — e.g. `Expression.hs:66-67`, `:79-80`, `:527-531` — rather than a boolean
`isProd`-style helper, which does not exist in `Generate.Mode` today.)

New functions, same file: a chain collector (walks both operand positions of `composeL`/`composeR`,
recursing only into saturated 2-arg calls, returning the ordered flat list of terminal `Opt.Expr` chain
links) and a body builder (applies `generateJsExpr` to each terminal leaf once, folds them via plain JS
calls around the fresh `$compose$n` parameter, in the order that preserves the original composition's
evaluation semantics — outermost function applied last, matching `composeL g f x = g (f x)`'s existing
meaning).

## Testing / verification protocol (no automated test suite in this repo, per `CLAUDE.md`)

1. **Historical regression, first-class test case:** compile `fromMaybe f = f << (<<) Just` (and the
   `>>` mirror, plus a couple of nested/parenthesized variants deliberately shaped like the original
   bug) with the new compiler, both Dev and Prod. Confirm Prod output has no self-referential `$(...)`-
   style pattern, and execute the compiled Prod JS under Node against representative inputs, comparing
   results against the same expression compiled by the **unmodified** baseline compiler (checksum/value
   equality, not just "it runs without throwing").
2. **Ordinary chains, growing length:** 2 through ~8-function chains of plain named functions, executed
   under Node, results compared against baseline for equality.
3. **Structural check:** grep the Prod output for the *absence* of a runtime `composeL`/`composeR` call
   in a flattened chain's generated function (confirming actual flattening occurred, not just "still
   correct but unoptimized").
4. **Dev-mode diff:** compile a representative set of chains in Dev mode before and after the change;
   output must be byte-identical (this is a Prod-only change).
5. **Real-compiler timing:** re-run the research phase's interleaved Node-process benchmark methodology
   (multiple chain lengths, checksum-verified, several repetitions) against the actual compiled output
   of a scratch Elm project, to confirm the 2x-5x range measured by hand-patch spikes holds with the
   genuine implementation — same rigor as every prior optimization in this fork's history (see e.g.
   [[list-foldl-fusion-plan]]'s verification protocol).

## Real-compiler verification results (added post-implementation, 2026-07-24)

Task 1 (implementation) and Task 2 (real-compiler verification) both completed and passed independent
review: structural flattening genuinely occurs, all correctness checks pass (including the historical
`elm/compiler#1722` regression case, concretely `fromMaybeUse(n) === n + 1`), and `Mode.Dev` output is
byte-identical before/after (confirmed via SHA-256, not just `diff`).

**V8/Node: no measured speedup.** Three independent timing protocols against real, hash-verified
before/after binaries (interleaved single-shot, 7-trial min/median, wide-non-repeating-input, later
repeated twice more with entirely fresh binaries/volumes to rule out any caching artifact) all show the
real-world difference within ~1-2% noise, sometimes `after` marginally slower. Root-cause hypothesis:
`chain2L = A2($elm$core$Basics$composeL, addOne, double)` resolves once, at module load, to a concrete
unary closure — the one extra monomorphic call layer this optimization removes is exactly the kind of
thing V8/TurboFan already inlines away after warmup, consistent with two prior findings in this fork's
history ([[closed-lambda-hoisting-spike]], [[partial-application-callback-spike]]).

**Firefox/SpiderMonkey: large, real, reproducible speedup.** Tested via Playwright-driven Firefox
(hash-verified binaries identical to the Node test, 5,000,000-iteration warmup to rule out JIT-tier
artifacts, order-reversed re-run, correctness-checked in-browser):

| chain | before | after | speedup |
|---|---|---|---|
| chain2L (2-stage) | 26-40ms | 26-30ms | ~1x (near-parity, noisy) |
| chain3L (3-stage) | 459ms | 32ms | **14.3x** |
| chain4L (4-stage) | 702-726ms | 21-40ms | **18-35x** |
| chain2R (2-stage) | 138-159ms | 28-44ms | **3.5-4.9x** |
| chain3R (3-stage) | 559ms | 43ms | **13.0x** |
| chain4R (4-stage) | 856-914ms | 26-42ms | **21-33x** |

SpiderMonkey does not eliminate the extra `composeL`/`composeR` dispatch layer the way V8 does. For
chains of 3+ stages the flattening delivers a substantial, real, order-independent speedup; only the
2-stage case is roughly a wash (both variants are already fast there).

**Conclusion:** the performance benefit of this optimization is real but **engine-dependent** — large on
Firefox, a no-op on V8/Chrome/Node. Since `elm make`'s primary deployment target is the browser (via
`elm/browser`, not exclusively Node), and Firefox is a mainstream target with no evidence the V8 result
generalizes negatively (no regression observed there, just no gain), this is a genuine, defensible case
for merging — reframed as "engine-dependent win, most valuable for browser/Firefox-facing Elm
applications with composition-heavy code," not the originally-hypothesized universal 2x-5x.

## Future work (not this design)

- `Random.andThen`/`mapN` chain fusion and `Maybe`/`Result` `andThen`-chain case-of-case fusion were
  also found in the same research sweep ([[optimization-research-sweep-2-summary]]) — separate designs,
  not bundled here.
- Extending recognition to chains passed through a `let`-bound intermediate name (currently out of
  scope, same restriction every existing fusion pass in this fork already accepts).
