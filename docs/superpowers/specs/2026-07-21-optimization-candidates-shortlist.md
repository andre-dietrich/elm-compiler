# Optimization candidate shortlist (2026-07-21)

Merged, deduplicated, filtered, and ranked from the two research tracks:
`docs/superpowers/specs/2026-07-21-optimization-candidates-v8.md` ("v8" below) and
`docs/superpowers/specs/2026-07-21-optimization-candidates-compilers.md` ("compilers" below).

Process: 6 raw candidates (3 per source file) were merged into 5 by combining the two
decision-tree-focused candidates (v8's cold-branch outlining and compilers' DAG/maximal-sharing
tree compilation), which independently converge on the same root cause — an oversized generated
`case`-dispatch function body — via complementary mechanisms. The remaining 5 were checked
against the Global Constraints filter ("bypass dispatch overhead on a monomorphic call site" —
the pattern behind the three already-discarded spikes: closed-lambda-hoisting,
partial-application-callback, html-tag-arity). None of the 5 match that pattern as their primary
mechanism, so none were dropped; all 5 survive, ranked below. Full reasoning in
`.superpowers/sdd/task-3-report.md`.

---

## 1. mutual-tailcall-cycle-fusion: Mutual tail-call optimization via cycle-fusion

**Hypothesis:** Fusing a mutually-tail-recursive cycle of functions into one JS function with a
`mode` variable and a `while` loop turns sibling tail calls into loop-continues, eliminating both
stack growth and per-bounce call overhead that no JS engine can otherwise remove.

**Expected win mechanism:** Changes algorithmic shape — converts recursion (a sequence of real
calls) into iteration, the same category as this fork's committed TRMC work. Also a correctness/
robustness win (removes a stack-overflow risk for idiomatic mutually-recursive Elm code, e.g.
hand-written recursive-descent parsers or per-state step functions), independent of any speed
delta.

**Dead-end risk:** Low. This is not a dispatch-bypass idea — it targets something no shipped JS
engine can do at all (proper tail calls across independent function objects), so it cannot be a
"V8 already handles this" dead end by construction. Main risk is scope/complexity of the codegen
change and how often mutually-tail-recursive top-level cycles actually occur in real Elm
programs.

**Source:** compilers doc, "Mutual tail-call optimization via cycle-fusion (loop + mode
variable)".

---

## 2. decision-tree-dag-sharing: Maximal-sharing decision-tree compilation with cold-branch outlining fallback

**Hypothesis:** `Optimize/DecisionTree.hs` rebuilds structurally identical subtrees independently
per parent edge (no cross-edge memoization), which can inflate a generated `case`/`switch`
function large enough to blow past TurboFan's per-callee inlining budget — a smaller, DAG-shaped
tree (building each distinct subtree once, sharing it via re-entrant jump labels the way
`Optimize/Case.hs` already does for leaves) shrinks that body directly; for the residual cases
that stay large despite sharing, outlining rarely-taken branches into separate helper functions
is a complementary way to fit the same budget.

**Expected win mechanism:** Changes algorithmic shape — deduplicating repeated test/branch
construction is a genuine compile-time elimination of redundant code, not a bypass of a call-site
dispatch that V8 already optimizes; it also unblocks TurboFan inlining/escape-analysis on the
enclosing function (e.g. so a `(Model, Cmd Msg)` tuple immediately consumed by the caller can be
scalar-replaced instead of allocated).

**Dead-end risk:** Low-medium. The DAG-sharing mechanism (compilers doc) is rated low-medium
because it is a code-size/redundant-work concern, not a dispatch-bypass one, but its payoff scales
with how often real `case` expressions match on multiple independent multi-constructor
scrutinees — likely a smaller, less certain win than a raw-speed one. The outlining fallback
(v8 doc) is rated medium-high on its own, since it only pays off for unions large enough to
already exceed the inlining budget and its gain is contingent on the caller benefiting from
inlining/escape analysis at that specific call site.

**Source:** v8 doc, "Outline cold branches of large decision-tree/case functions to fit
TurboFan's inlining budget"; compilers doc, "Maximal-sharing (DAG) decision-tree compilation for
multi-scrutinee/nested pattern matches" (which explicitly cross-references the v8 candidate as
addressing the same downstream code-size/inlining-budget problem).

---

## 3. static-shape-record-clone: Static-shape record-update clone

**Hypothesis:** `generateInlineUpdate`'s `for...in` + `$updated[$key] = $record[$key]` copy loop
is a keyed (dynamic-key) store on every field of every record update, which can never get a
monomorphic named-property IC regardless of call-site heat — replacing it with either a single
`Object.assign({}, record)` call (cheap, no type-plumbing) or, where the closed field set is
known, one fully static object literal (`{ a: newA, b: record.b, c: record.c }`) should be faster
and, in the static-literal case, small enough for TurboFan to scalar-replace via escape analysis.

**Expected win mechanism:** Eliminates traversal/allocation-adjacent overhead — turns a
dynamic-key enumerate-and-copy loop into either a builtin fast path (`Object.assign`) or a fully
static literal with named-property (monomorphic IC) field reads, and makes the clone shape-small
enough for escape analysis to elide entirely at hot, immediately-consumed call sites (e.g. Elm's
Msg-dispatch `update`).

**Dead-end risk:** Medium. V8's `EnumCache`-based fast for-in already removes much of the
enumeration overhead this targets, so the cheap `Object.assign` swap alone may show only a modest
win; the bigger static-literal variant has a clear mechanistic reason (keyed vs. named store) to
expect a real difference but is the most expensive of the record/equality candidates to build
(needs the closed record's full field list threaded from type-checking through `Optimize.Expression`,
not just the updated fields `AST.Optimized` carries today).

**Source:** v8 doc, "Static-shape record-update clone (eliminate the generic `for...in` +
keyed-store copy loop)".

---

## 4. closed-type-structural-equality: Field-by-field structural equality for closed record/union types

**Hypothesis:** Structural `==` on two values of a statically-known, closed (non-recursive,
non-row-polymorphic) record or union type always falls through to the generic `_Utils_eq` kernel
walk (type-reflecting, `for...in`-based, dynamic-keyed field comparison) regardless of how
monomorphic the call site is — where the type checker can prove closedness (extending the
existing `toPrimType`/`CProbe` mechanism used for scalar prim-op specialization), the compiler
could unroll the comparison into a flat expression of static field accesses or tag-based
constructor comparisons.

**Expected win mechanism:** Eliminates traversal — turns a generic runtime-reflecting recursive
walk (dynamic keyed field reads, tag inspection) into static named-property reads, the same
mechanism this fork's already-committed prim-binop specialization (2.7x-5.6x on scalars) already
proved out one type-tag level down.

**Dead-end risk:** Medium. The keyed-vs-named mechanism argument is sound and mirrors a pattern
this fork has already shipped successfully, but the type-plumbing cost (recursive closedness
proof over an arbitrary record/union shape, not just a 4-way scalar tag) is the highest of the
record/equality-related candidates here, and full-`Model`-sized structural equality checks are
less common in typical Elm code than the scalar comparisons the existing work already covers, so
practical payoff is less certain even though the mechanism is real.

**Source:** v8 doc, "Field-by-field structural equality for statically-known concrete
record/custom types".

---

## 5. array-index-adt-tuple-repr: Array/index-based (untagged) representation for ADT constructors and tuples

**Hypothesis:** Representing non-erased ADT constructors and tuples as plain JS arrays
(`[tag, a, b]`) instead of objects with named `a1`/`a2`-style fields would trade named/keyed
property access for indexed-element access (V8's `PACKED_ELEMENTS` fast path) and shrink emitted
code size, following a pattern PureScript measured as a real bundle-size and micro-benchmark win.

**Expected win mechanism:** Changes representation/algorithmic shape (object vs. array container)
plus a code-size reduction, in the same general family as this fork's already-successful
ADT-shape-padding work — but here it is a smaller *increment* on top of what shape-padding
already fixed (hidden-class fragmentation), not a fresh mechanism.

**Dead-end risk:** Medium-high. This fork's shipped ADT-shape-padding work already addresses the
main V8-facing problem with the current object encoding, and field-shortening already captures
most of the code-size angle; the remaining unique contribution (keyed-vs-indexed access) is real
but likely a smaller increment, for an implementation cost — rewriting every kernel-JS consumer
of ADT/tuple shape (`_List_Cons`, `Dict`, `_Utils_eq`, `Debug.toString`, JSON codecs) plus the
`DecisionTree`/`Case` path codegen — that dwarfs every optimization this fork has shipped so far.
Best scoped to ADT constructors and tuples only, never records, given the row-polymorphic-naming
complication the source doc raises.

**Source:** compilers doc, "Array/index-based (untagged) representation for ADT constructors and
tuples".
