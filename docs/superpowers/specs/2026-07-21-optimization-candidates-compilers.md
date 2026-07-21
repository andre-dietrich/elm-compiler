# FP-to-JS compiler research notes for optimization sweep (2026-07-21)

Scope: research how PureScript, ReScript/BuckleScript, Gleam, Roc, and Fable compile (a)
pattern matching, (b) currying/arity, (c) records/tuples, and (d) tail calls, then
cross-reference every technique found against this fork's existing
`Optimize/DecisionTree.hs`, `Optimize/Case.hs`, `Generate/Mode.hs` (`Arities`/
`computeArities`), and `Generate/JavaScript/Expression.hs` (TRMC, ctor/tuple/record
codegen), plus prior spikes recorded in
`/home/andre/.claude/projects/-home-andre-Workspace-Projects-Freinet-elm-compiler/memory/*.md`.
See `.superpowers/sdd/task-2-report.md` for the full research log and exclusion list.

Two of the three surviving candidates below target something this fork's compiler has
never attempted at all (mutual tail-call optimization is not implemented for *any*
language target's compiler on the JS side, including Gleam's, as of this research —
it's an open, actively-worked problem there too), rather than a refinement of dispatch
that V8 already does well. The third (array/index-based ADT representation) is the one
closest in flavor to previously-discarded dispatch-bypass ideas, and is flagged
accordingly.

---

## Candidate: Mutual tail-call optimization via cycle-fusion (loop + mode variable)

**Source:** Gleam, JS target — https://github.com/gleam-lang/gleam/issues/3830 (open,
unimplemented as of this research). Gleam already lowers *self*-recursive tail calls to a
loop on its JS backend (same shape as this fork's `Opt.TailCall`/`while` loop), but has no
mutual-tail-call optimization on the JS target yet, because V8 has no native
proper-tail-calls. The issue's proposed fix — explicitly rejecting both trampolines (extra
closure allocation per bounce) and CPS — is to fuse all mutually-tail-recursive functions
in one cycle into a single JS function with a `mode`/`state` parameter that a `while` loop
switches on: what would have been a tail call to a sibling function instead becomes
"update `mode` and the loop's local bindings, `continue`" instead of an actual call.
Each original function name becomes a thin wrapper that seeds the loop with the right
starting mode.

**Rationale:** This fork's own tail-call optimizer (`Optimize/Expression.hs`,
`matchTailSelfCall`) only recognizes a call as tail-optimizable when
`rootName == name` — i.e., literal self-recursion. `Opt.Cycle` (see
`Generate/Mode.hs`'s `addCycleFunc`/`cycleArity`) already groups a mutually-recursive
`let`-block's members into one bundle for *arity-tracking* purposes, but
`Optimize/Expression.hs` never asks whether a call from one cycle member to another,
in tail position, could also become a loop transition — those calls stay ordinary
JS function calls today. This is a real, currently-unaddressed stack-overflow risk
for idiomatic Elm patterns that use mutual recursion in tail position (hand-written
recursive-descent parsers, mutually-recursive state-machine step functions, one
function per state). It is not a "V8 already handles this" case: no widely-shipped JS
engine implements proper tail calls (V8 dropped its early attempt), so a stack-overflow-prone
mutually-recursive Elm program genuinely crashes today, regardless of how well V8
optimizes dispatch — this is a correctness/robustness gain, not just a speed one,
though collapsing several small functions into one loop body can also remove call
overhead V8 cannot itself eliminate (no engine turns a real call into a loop iteration).

**Touch points:** `Optimize/Expression.hs` (`matchTailSelfCall`, `optimizeTail`,
`hasTailCall` would all need to accept "call to any cycle member, not just `rootName`",
and the existing `TailCall`/`DefineTailFunc`/`Opt.Cycle` `AST.Optimized` shapes would need
a new variant for "fused mutual-tail loop" analogous to how `TailCallCons` was added
alongside plain `TailCall` for TRMC) and `Generate/JavaScript/Expression.hs`
(`generateTailDefCons`/the `while`-loop codegen path, which would need a `mode`-switch
variant, plus each original name becoming a wrapper that calls the fused function with
the right starting mode and argument layout — the different cycle members likely have
different arities/argument names, so the fused loop body needs a shared parameter
frame). This is a substantially bigger `AST.Optimized`/codegen change than any prior
TRMC increment (it changes multiple distinct top-level definitions into one), so expect
a `.elmo` binary-format bump per CLAUDE.md's notes on `Opt.*` changes.

**Risk of being a V8-already-handles-this dead end:** Low — this is not a dispatch-bypass
idea (the class of idea this fork's discarded spikes falsified); it targets a case JS
engines structurally cannot handle at all (no proper tail calls across independent
function objects), so any win here is a genuine capability the runtime doesn't provide,
not a race against an already-good JIT heuristic. The main risk is scope/complexity
(fusing N functions' bodies and argument lists into one loop is a bigger-than-usual
codegen change) and that mutually-tail-recursive top-level cycles may be rare enough in
typical Elm programs that the payoff, while real when it triggers, triggers infrequently.

---

## Candidate: Maximal-sharing (DAG) decision-tree compilation for multi-scrutinee/nested pattern matches

**Source:** Jules Jacobs, "How to compile pattern matching" (2021),
https://julesjacobs.com/notes/patternmatching/patternmatching.pdf — builds on Luc
Maranget's "Compiling Pattern Matching to Good Decision Trees" (2008),
http://moscova.inria.fr/~maranget/papers/ml05e-maranget.pdf, which already discusses
decision trees as DAGs "with maximal sharing" as an extension of the basic algorithm.
Gleam's pattern-match compiler cites Jacobs' note directly as the basis for its own
decision-tree construction (per Gleam's pattern-matching documentation/DeepWiki summary
found during this research).

**Rationale:** `Optimize/DecisionTree.hs`'s `toDecisionTree` is the classic
Maranget/SML-NJ heuristic-driven algorithm (the module's own header comment says so
explicitly) — `gatherEdges` partitions branches per constructor test and then calls
`toDecisionTree` **recursively and independently** on each edge's sub-branches and on the
fallback. There is no memoization or hash-consing across sibling subtrees: if two
different edges of a `Decision` node happen to produce structurally identical decision
trees (a common case for pattern matches over **multiple independent scrutinees**, e.g.
`case (flag, status) of` where `flag`'s two arms both need the same subsequent test on
`status`), the current algorithm regenerates that subtree's tests once per parent edge
rather than building it once and sharing it. This fork's own `Optimize/Case.hs` already
does *leaf*-level sharing (multiple leaves that reach the same RHS `goal` index jump to
one shared label — see the `DecisionTree.hs` header comment on this), which covers the
common "same right-hand side reached from several patterns" case, but that is a
narrower, different mechanism than subtree-level DAG sharing: it dedupes only what runs
*after* a match is fully decided, not the *test sequence* used to get there. For pattern
matches over a tuple/record of multiple non-trivial unions (each with several
constructors), naive per-edge tree construction can reproduce the same test chain many
times, inflating the generated `switch`/`if` chain — directly working against the
"outline cold branches to fit TurboFan's inlining budget" candidate already proposed in
the V8-sourced research (`docs/superpowers/specs/2026-07-21-optimization-candidates-v8.md`),
since a smaller decision tree needs no outlining to begin with.

**Touch points:** `Optimize/DecisionTree.hs` (`toDecisionTree`/`gatherEdges` would need a
memo table keyed on the (structurally normalized) remaining-branch set, producing a DAG
of decision nodes rather than a tree — plus a stable way to name/re-enter a shared node,
since a shared subtree can now be reached from more than one parent) and
`Optimize/Case.hs` (the existing `Jump`/label mechanism already solves the "reuse from
multiple entry points" problem for leaves; it would need to generalize to arbitrary
interior decision nodes, not just leaves, likely by turning shared *interior* nodes into
their own labeled jump targets the same way shared leaves are today).

**Risk of being a V8-already-handles-this dead end:** Low-medium — this is a code-size
and (indirectly) inlining-budget concern, not a call-dispatch-bypass idea, so it doesn't
fall into the class of ideas this fork's V8-IC research shows are dead ends; the risk is
instead that the payoff is proportional to how often real Elm `case` expressions actually
match on multiple independent, multi-constructor scrutinees at once (single-scrutinee
matches, by far the common case, get no benefit since there is only one branch per edge
to begin with) — likely a smaller and more code-size-shaped win than a raw-speed one,
and the implementation (turning a tree algorithm into a DAG one with re-entrant labeled
nodes) is nontrivial.

---

## Candidate: Array/index-based (untagged) representation for ADT constructors and tuples

**Source:** PureScript compiler experiment, "Representing data constructors as plain
arrays to reduce code size (and possibly increase performance)" —
https://discourse.purescript.org/t/experiment-representing-data-constructors-as-plain-arrays-to-reduce-code-size-and-possibly-increase-performance/585.
The patch changed constructors from objects with named `value0`/`value1`-style fields
(plus a `.create` method) to plain JS arrays (`[tag, a, b]`, or with the tag itself
omitted for common cases), measuring a real-world bundle-size drop (652.59KB →
599.72KB on purescript-halogen-realworld) and a ~22% improvement on one `Map`
construction micro-benchmark; a commenter also noted the object-based encoding
"gzips very well" but minifies worse than the array form. Cross-referenced against
ReScript's variant encoding (https://rescript-lang.org/docs/manual/variant/), which
already special-cases zero-payload constructors (bare string, no wrapper at all) and
single-constructor-with-payload types (object without a `TAG` field) — i.e. ReScript,
too, treats "does this value need a discriminant at all" as a per-shape question rather
than uniformly wrapping every constructor the same way.

**Rationale:** `Generate/JavaScript/Expression.hs`'s `generateCtor`/`generateTuple` build
every non-erased ADT value and every tuple as a JS **object** with a `$` tag field (an
int in Prod, per the ADT-shape-padding work already on `main`) plus one named property
per argument (`a1`, `a2`, ... after field-shortening). This fork has already invested
in making that *object* shape as V8-friendly as possible (monomorphic hidden classes via
null-padding, short field names) — the open question this candidate raises is whether an
object is the right container at all versus a plain array (`[tag, a, b]`), which trades
named/keyed property access for indexed elements access. V8's `PACKED_ELEMENTS` fast path
for small arrays is a different (and for some access patterns, cheaper) mechanism than
named-property ICs on a HiddenClass, and — independent of runtime speed — dropping
per-field property names shrinks emitted code size, which this fork has generally
correlated with real end-to-end wins elsewhere (list/kernel padding, field-shortening).

**Touch points:** `Generate/JavaScript/Expression.hs` (`generateCtor`, `generateTuple`,
`generateRecord` would need array-emitting counterparts) and, far more extensively,
every consumption site that currently assumes an object shape: `Optimize/DecisionTree.hs`/
`Optimize/Case.hs`'s `Path`/`Index`/`Field` codegen (`generatePath`, `pathToJsExpr`,
`generateIfTest`/`generateCaseTest`'s `.dollar`/named-field access), and — the largest
blast radius by far — the hand-written kernel JS runtime (`_List_Cons`, `Dict`'s
`RBNode_elm_builtin`, `_Utils_eq`'s generic structural-equality walk, `Debug.toString`'s
generic reflection over `.$`/named fields, JSON encoders/decoders that inspect ADT shape)
which is JS source text, not something the type-directed codegen can silently
reinterpret — every one of these would need a parallel array-aware code path, or the
whole kernel would need rewriting to match. Records specifically are harder still:
unlike ADTs/tuples, records are structurally used by field *name* throughout the
program (`.field` access sites are generated per name, not per positional index) and
open/extensible-record polymorphism (row types) depends on being able to look a field
up by name across differently-shaped values — an array encoding would need a stable,
whole-program-computed name→index table (similar in spirit to `shortenFieldNames`, but
positional instead of just renaming), which is a much bigger type-directed-compilation
problem than the tag/argument case for closed ADTs and tuples.

**Risk of being a V8-already-handles-this dead end:** Medium-high — this fork's existing
ADT-shape-padding work (committed, +5-10% measured) already addresses the main V8-facing
problem with the current object encoding (hidden-class fragmentation across a union's
variants), and field-shortening already captures most of the code-size angle PureScript's
experiment reports; what would remain as *this* candidate's unique contribution is the
keyed-vs-indexed access-mechanism difference, which is a real but likely smaller
increment on top of what shape-padding already fixed, for an implementation cost (rewrite
every kernel-JS consumer of ADT/tuple shape, plus solve the row-polymorphic-record naming
problem) that dwarfs every optimization this fork has shipped so far. Best scoped as
"ADT constructors and tuples only, not records" if ever attempted, given the row-typing
complication above.

---

## Also verified as already implemented or out of scope (not new candidates)

- **Single-constructor "newtype" erasure.** `AST.Canonical`'s `CtorOpts` already has an
  `Unbox` variant (alongside `Normal`/`Enum`), and in Prod mode this fork already fully
  erases values of a single-constructor, single-field type: the constructor itself
  compiles to `identity` (`Generate/JavaScript/Expression.hs`'s `Opt.VarBox`/`Opt.Box`
  handling), pattern-match tests on it are skipped entirely (`Can.Unbox -> value`, no tag
  read), and `DT.Path`'s `Unbox` case is a no-op passthrough in Prod. This is exactly the
  "opaque wrapper has zero runtime cost" property PureScript/ReScript's single-constructor
  special-casing is reaching for — already present here (this appears to be inherited
  from upstream Elm, not fork-added, but either way it rules out writing this up as a new
  idea).

- **PureScript's default currying (nested single-arg closures).** PureScript's default
  codegen curries every function into a chain of one-argument closures — structurally
  *worse* than what this fork already does (uncurried functions with whole-program
  `Arities`-driven A2..A9-bypass at every statically-resolvable call site), not a
  technique to adopt.

- **ReScript's type-level uncurried arity (`function$<fun_type, arity>`).** ReScript
  avoids runtime arity dispatch for the common case by making uncurried functions the
  *default in the source language*, with currying as an explicit opt-in construct — a
  language-design choice, not a codegen technique, and not portable to Elm without
  changing what `->` means in Elm's type system (out of scope for a JS-codegen-only
  change, and a much bigger project than anything else in this sweep).

- **Roc's closure defunctionalization (switch-on-integer instead of function-pointer
  indirection).** Per https://www.rwx.com/blog/how-roc-compiles-closures, this technique
  exists to avoid actual pointer/vtable indirection at the LLVM/native level. A JS
  function call already goes through V8's own optimized call mechanism (inline caches on
  the call site), so this reduces to the same "bypass generic dispatch at a call site"
  shape this fork's `partial-application-callback-spike` and `closed-lambda-hoisting-spike`
  already measured as ~1% noise, V8-already-handles-this. Not re-proposed.

- **Fable's F#-to-JS uncurrying heuristics.** Fable's uncurrying logic
  (https://fable.io/docs/javascript/features.html and related interop docs) is entirely
  about the F#↔JS interop boundary (guessing whether an incoming/outgoing function value
  should be curried or not, since F#'s type system can't always tell arity apart from
  nested single-arg functions) — an interop-correctness concern with no analog in an
  Elm-to-JS compiler that has no F#-style structural ambiguity between `a -> b -> c` and
  `a -> (b -> c)` (Elm's own `Arities`/whole-program analysis already resolves this more
  precisely than Fable's heuristic needs to).
