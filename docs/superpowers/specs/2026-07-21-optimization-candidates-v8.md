# V8-internals research notes for optimization sweep (2026-07-21)

Scope: research current V8 optimizer/GC behavior, then cross-reference every technique
against this fork's existing `Generate/JavaScript`/`Generate/Mode.hs` codegen and against
prior spikes recorded in `/home/andre/.claude/projects/-home-andre-Workspace-Projects-Freinet-elm-compiler/memory/*.md`.
Anything already implemented or already spiked (positive or negative) was dropped. See
`.superpowers/sdd/task-1-report.md` for the full research log and the (longer) exclusion
list with reasoning.

The common thread in this fork's *discarded* spikes (closed-lambda-hoisting,
partial-application-callback bypass, html-tag arity propagation) is that V8's inline
caches already make monomorphic call-site dispatch and monomorphic property access
close to optimal — "bypass a generic dispatch helper" ideas are dead ends unless they
also change what gets allocated or what kind of property-access mechanism (named vs.
keyed) is used. The three candidates below were selected because each changes one of
those two things, not just call-site dispatch.

---

## Candidate: Static-shape record-update clone (eliminate the generic `for...in` + keyed-store copy loop)

**Source:** https://v8.dev/blog/fast-properties — "the same named properties in the
same order share the same HiddenClass"; adding properties one at a time via assignment
walks a HiddenClass transition tree rather than jumping straight to a precomputed
literal shape. Cross-checked against https://v8.dev/blog/fast-for-in (V8's `EnumCache`
made bare enumeration ~3x faster, but the article documents only enumeration speed, not
the cost of the `obj[key] = ...` *keyed store* done with each enumerated key) and the V8
IC-design notes on `KeyedStoreIC` (a runtime string key can only ever hit the generic/
megamorphic keyed-store handler, never a monomorphic named-property store, because the
IC keys on `{map, propertyName}` pairs and the property name here is a runtime value,
not static text) — see https://groups.google.com/g/v8-reviews/c/ThnDKjcRRBQ and
https://v8.dev/blog/elements-kinds for the general packed/monomorphic-vs-generic
distinction this stems from.

**Rationale:** `generateInlineUpdate` (`Generate/JavaScript/Expression.hs`, always used
in Prod per the tier2-record-update-spike memory) still does:
```js
var $updated = {};
for (var $key in $record) { $updated[$key] = $record[$key]; }
$updated.a = newA;               // then static overwrites for changed fields
```
The tier2 spike explicitly recorded that this loop was *not* removed — only the second
"updatedFields object + mini-loop" that used to sit on top of it was. The remaining
`for...in` + `$updated[$key] = ...` is a **keyed** (dynamic-key) store on every field of
every record on every update, which cannot get a monomorphic named-property IC no matter
how hot the call site is — a fundamentally different mechanism than the call-dispatch
ideas that were already spiked and found to be no-ops. Where the record's exact,
non-extensible field set is statically known at the update site (the overwhelmingly
common case — e.g. `{ model | count = model.count + 1 }` in a concrete, closed `Model`),
the compiler could instead emit one fully static object literal
(`{ a: newA, b: record.b, c: record.c }`) with no loop at all: this gets V8's
precomputed-literal-shape fast path and turns every base-field read into a static named
`.b`/`.c` access (monomorphic IC) instead of a keyed one. A cheaper, still-generic
intermediate step (works even for open/extensible records, no type-plumbing needed)
is replacing the loop with a single `Object.assign({}, record)` call, which is an ES5-
legal builtin (no new syntax needed in `Generate/JavaScript/Builder.hs`, which is
deliberately ES5-only per the tier1 notes) and has had a dedicated V8 fast path (CSA-based,
since 2018) that a hand-rolled `for...in` loop cannot compete with. This also matters for
escape analysis: an update site whose result is immediately consumed (e.g. Elm's Msg
dispatch loop) can only have its intermediate object scalar-replaced by TurboFan if the
whole clone operation is small/inlinable — a `for...in` loop is not a shape TurboFan
scalar-replaces, whereas a flat static literal is exactly the kind of allocation escape
analysis is best at eliding.

**Touch points:** `Generate/JavaScript/Expression.hs` (`generateInlineUpdate`,
`generateInlineUpdateBody`) for both the cheap (`Object.assign`) and full (static
literal) variants. The full static-literal variant additionally needs the closed
record's complete field set to survive from type-checking into `Opt.Update` — today
`AST.Optimized`'s `Update Expr (Map Name Expr)` only carries the *updated* fields, not
the base record's full field list, so that variant would also touch
`Type.Constrain.Expression`/`AST.Canonical` (determining "closed vs. row-polymorphic" at
the update site) and `Optimize.Expression` (threading the extra info through, similar in
shape to how `Hints` were threaded for prim-binop specialization).

**Risk of being a V8-already-handles-this dead end:** Medium — V8's `EnumCache`-based
fast for-in already removes a lot of the *enumeration* overhead this idea targets, so the
`Object.assign` swap alone may show only a modest win; the bigger, type-plumbing-heavy
static-literal variant is the one with a clear mechanistic reason (keyed vs. named store)
to expect a real difference, but it is the most expensive to build of the three
candidates here.

---

## Candidate: Outline cold branches of large decision-tree/case functions to fit TurboFan's per-function inlining budget

**Source:** community-compiled V8 flag documentation (default values, confirmed via
gist/GitHub mirrors of V8's flag definitions) — `--max-inlined-bytecode-size` defaults to
500 bytecode units for a single inlined callee, `--max-inlined-bytecode-size-cumulative`
to 1000, `--max-inlined-bytecode-size-absolute` to 5000 for a whole inlining unit; see
https://v8.dev/docs/turbofan and https://github.com/thlorenz/v8-perf/blob/master/compiler.md
for the general "large functions are never inlined, tiny functions almost always are, and
there's a cumulative budget after which no more inlining happens" framing. Cross-checked
against the V8 escape-analysis blog (https://v8.dev/blog/v8-release-71 — escape analysis
eliminated up to 40% overhead by fully eliding context/closure allocation in higher-order
functions) since escape analysis only reaches across a call boundary that actually got
inlined.

**Rationale:** `Generate/JavaScript/Expression.hs`'s `generateDecider`/`generateCase`
lowers Elm's compiled decision tree (`Optimize/Case.hs`, `Optimize/DecisionTree.hs`)
directly into one JS `switch`/`if` chain inside the enclosing function body — there is no
size limit or splitting today. For a real-world Elm program's `update : Msg -> Model ->
(Model, Cmd Msg)` (a case over a Msg union that can easily have dozens of variants, each
with a non-trivial branch), the generated function body can be large enough to exceed
TurboFan's ~500-bytecode single-callee inlining budget on its own, independent of how hot
the call site is. This matters more than plain call overhead (which the discarded spikes
showed V8 already handles well): if `update` cannot be inlined into the runtime's message-
dispatch loop, then the `(Model, Cmd Msg)` tuple it returns can never be scalar-replaced
by escape analysis either, even in the common case where that tuple is immediately
destructured and discarded by the caller. Outlining infrequently-taken branches (or,
conservatively, splitting one enormous decision tree into a small dispatcher plus
per-branch helper functions only for unions above some variant-count threshold) would
shrink the always-generated dispatcher body enough to stay under the inlining budget for
the hot/common branches, at the cost of one extra (cheap, monomorphic) call for the rare
branches.

**Touch points:** `Generate/JavaScript/Expression.hs` (`generateCase`/`generateDecider`/
`generateCaseBranch`, where branch bodies would need to become separate top-level/local
function definitions instead of inline statements) and `Optimize/Case.hs`/
`Optimize/DecisionTree.hs` (would need some notion of branch "coldness" or a variant-count
threshold to decide what to outline, since the decision tree itself has no frequency
information today).

**Risk of being a V8-already-handles-this dead end:** Medium-high — this only pays off for
unions large enough that the generated function actually exceeds the inlining budget
(small Elm apps with small Msg types likely never hit this), and even when it does, the
gain is contingent on the caller actually benefiting from inlining/escape analysis at that
specific call site rather than just avoiding one already-cheap monomorphic call.

---

## Candidate: Field-by-field structural equality for statically-known concrete record/custom types

**Source:** same V8 IC-mechanism sources as the record-update candidate
(https://v8.dev/blog/fast-properties, https://v8.dev/blog/elements-kinds) plus this
fork's own committed measurement in `prim-binop-specialization-plan.md`, which found that
scalar `==`/`</>`/`++` specialization gave 2.7x-5.6x wins by replacing a generic kernel
call with a raw JS operator.

**Rationale:** The prim-binop specialization plan explicitly scoped itself to Int/Float/
Bool/String and left `Char`, `List ++`, and anything going through `comparable`/generic
equality on the generic `_Utils_eq` kernel path. Structural equality on a *concrete,
monomorphic* record or custom-type value (e.g. comparing two `Model` values, or two
values of a known, closed union) still always calls `_Utils_eq`, which does a runtime
type-reflecting recursive walk (checks `typeof`, reads the `$` tag, and — like the record-
update loop above — enumerates fields with `for...in` and compares them via dynamic keyed
access) every single time, regardless of how hot or monomorphic the call site is. Where
the type checker can already prove (the same kind of proof `Type.toPrimType` does for
scalars) that both operands share one *closed*, non-recursive-through-a-type-variable
record or union shape, the compiler could unroll the comparison into a flat expression of
static field accesses (`a.x === b.x && a.y === b.y`) or a tag-based per-constructor
comparison — turning both the dispatch (already fast) and, more importantly, every field
read from keyed/generic to static/named, the same underlying mechanism change as the
record-update candidate above.

**Touch points:** `Generate/JavaScript/Expression.hs` (a new `generateStructEq` alongside
the existing `equal`/`strictEq`, parallel to how `generatePrimOp` sits alongside `equal`),
`AST.Optimized` (a new `Opt.PrimOp`-like variant carrying the concrete field/constructor
list, or extending `Opt.PrimOp`'s existing hint-passing machinery), and — the expensive
part — `Type.Constrain.Expression`/`Type.Solve` to extend the existing `CProbe`/
`toPrimType` mechanism from "is this one of 4 scalar tags" to "is this a closed record (with
its field list) or closed union (with its constructor list), recursively, with no leftover
type variable."

**Risk of being a V8-already-handles-this dead end:** Medium — the mechanism argument
(keyed vs. named property access, same as the record-update candidate) is sound, but the
type-plumbing cost is the highest of all three candidates here (recursive closedness
proof, not just a 4-way tag), and unlike scalar equality, a full structural walk is
usually not on as hot a path in typical Elm apps (equality checks over full `Model`-sized
records are rarer than the `count == count` style scalar comparisons the existing work
already covers), so the practical payoff is less certain even if the mechanism is real.

---

## Also verified as already safe (not a candidate, no action needed)

`generateRecord` builds every record object from `Map.toList fields` (`Generate/JavaScript/Expression.hs:292`),
and Haskell's `Map` iterates in key order — so two construction sites for the same record
*shape* (same field names) always emit fields in the same canonical order regardless of
the order the programmer wrote them in source. This is exactly the V8 gotcha
`fast-properties` warns about ("the same properties added in a different order produce a
different HiddenClass") — but the fork's use of `Map.Map Name.Name Opt.Expr` already
guarantees a canonical order for free, so no HiddenClass fragmentation is possible here.
No candidate needed; this was a "verify, don't propose" finding from the record-update
research above.
