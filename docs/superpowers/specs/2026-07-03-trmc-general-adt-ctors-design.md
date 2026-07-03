# TRMC for general ADT constructors — design

Date: 2026-07-03

## Context

Tail recursion modulo cons (TRMC) V1 (`9807c654`) compiles `x :: recurse
rest` — a Kernel `List.cons` application whose right operand is a direct
saturated self-call in tail position — into a `while` loop that builds the
result list top-down via a sentinel cell and hole mutation, instead of a
non-tail recursive call whose JS stack depth is bounded by input length.
Benchmarked at ~1.7-2.1x on list-building loops, with the dominant real
win being robustness: the naive recursive form crashes
(`RangeError: Maximum call stack size exceeded`) around 6300 elements on
V8's default stack, while the loop form handles 1,000,000 elements in
~14ms.

V1 is deliberately scoped to **only** the Kernel `List.cons` constructor —
see `memory/trmc-plan.md`. General user-defined ADT constructors (e.g.
`Node l v (recurse rest)` for a binary tree) are not covered. This is
flagged there as "the largest remaining item" in this fork's perf work.
This design extends the mechanism to arbitrary `Can.Normal` constructors.

## Scope & restrictions

- The recursive "hole" argument may appear at **any position** in a
  saturated constructor call (not just the last field, as List's tail
  field happens to be). Detection scans a constructor call's arguments
  **right-to-left** for the first (rightmost) argument that is a
  **direct** self-call — i.e. `Can.Call` to the def's own name with no
  further nesting through `If`/`Case` on that argument, exactly the
  existing `matchTailSelfCall` restriction V1 already applies to List's
  right operand.
- If a constructor call has **more than one** self-call argument (e.g. a
  tree-rebuilding function recursing into both children), only the
  rightmost one becomes the accelerated hole. Earlier self-call arguments
  compile as ordinary (non-tail, still stack-consuming, still correct)
  recursive calls — the same rule OCaml's and jfmengels' TRMC use.
- A **pre-scan**, `detectConsIdentity`, runs once per def before
  optimization, over the raw `Can.Expr` (not the `Opt.Expr` under
  construction). It mirrors `optimizeTail`'s own tail-position structural
  traversal (`If`/`Let`/`LetRec`/`LetDestruct`/`Case`) and collects every
  candidate `(ctor identity, hole field index)` pair reachable in tail
  position. If the collected set has more than one distinct member, TRMC
  is disabled for that def **entirely**: no `TailCallCons` node is
  produced anywhere in the def, and it falls back to today's behavior
  (plain `Opt.TailCall` if a bare self-call exists in tail position, or no
  tail-call optimization at all if every tail position is behind
  ctor-wrapping).
  - **Consequence:** this also enforces one fixed **hole field index**
    per def, not just one ctor. A def whose branches build the same ctor
    but recurse into different fields on different branches (e.g.
    sometimes left, sometimes right) is disqualified too — codegen needs
    a single hole field name valid for the whole loop
    (`end.<hole> = cell`), not a per-branch one.
  - This is a deliberate v1 simplification chosen over a per-branch
    multi-slot accumulator scheme, which would be substantially more
    implementation and verification work for a rare real-world pattern.
  - Doing this as a pure pre-scan (rather than tentatively building
    `Opt.TailCallCons` nodes and rewriting/discarding them after the
    fact if a conflict is found later) avoids any backtracking over the
    `Names.Tracker` monad's dependency-collection side effects.
- Only `Can.Normal` ctor opts qualify. `Can.Enum` (0-arity — nothing to
  recurse into) and `Can.Unbox` (single-field newtype-style wrapper,
  where a recursive-only field would only ever produce a trivial
  degenerate case) are excluded from this round.
- Mutual recursion across multiple defs (`Cycle` nodes with more than one
  member calling each other) stays out of scope, matching V1's existing
  restriction.
- List keeps working exactly as before: `ConsKernel` (see below)
  reproduces V1's exact current codegen, so this change must not alter
  List TRMC's output at all — verified by re-running the V1 `myMap`
  scratch test and diffing.

## Data model changes (`AST.Optimized`)

Generalize the three existing TRMC constructors to carry a constructor
descriptor instead of being hardcoded to List:

```haskell
data ConsInfo
  = ConsKernel                    -- Elm.Kernel.List Cons/Nil, fixed 2-field, hole = index 1
  | ConsCtor Global Int           -- user ctor global + total field arity

-- was: TailCallCons Name Expr [(Name, Expr)]
TailCallCons ConsInfo Index.ZeroBased Name [(Index.ZeroBased, Expr)] [(Name, Expr)]
--            ^ctor    ^hole field   ^rootName  ^other fields, in position order   ^rebinds (unchanged)

-- was: TailCallConsBase Name Expr
TailCallConsBase ConsInfo Index.ZeroBased Name Expr

-- was: TailDefCons Name [Name] Expr
TailDefCons ConsInfo Index.ZeroBased Int Name [Name] Expr  -- +ctor, +hole index, +total arity
```

- `ConsKernel` reproduces exactly what V1 does today (`_List_Cons` /
  `_List_Nil`, hole = field `b`) — existing List TRMC output is
  unaffected byte-for-byte.
- `ConsCtor (Global home name) arity` covers user constructors: sentinel
  and cells are built by calling the ctor's own generated JS constructor
  function (`JsName.fromGlobal home name`) with `arity` positional args,
  one of which is the hole.
- This is another `.elmo` wire-format change (tags 28/29 on `Expr`, tag 2
  on `Def` all get wider payloads) — same cache-invalidation drill as the
  last three optimizations touching this format: fresh `ELM_HOME` volume,
  delete root-owned `elm-stuff` / `reactor/elm-stuff` caches from earlier
  Docker runs.

## Detection algorithm (`Optimize.Expression`)

- **`detectConsIdentity :: Name.Name -> [Name.Name] -> Can.Expr -> Maybe (ConsInfo, Index.ZeroBased)`**
  — pure pre-pass, structurally mirroring `optimizeTail`'s tail-position
  traversal, but building nothing. At each tail leaf: is this a
  `Can.Binop` on `List.cons` (candidate `ConsKernel`, hole index =
  `Index.second`)? Or a saturated `Can.Call` on a `Can.Normal` `VarCtor`
  (scan its args right-to-left via `matchTailSelfCall`; if one matches at
  position `i`, candidate `ConsCtor (Global home name) (length args)` at
  hole index `i`)? Collects all candidates; returns `Just identity` only
  if the collected set is a singleton, `Nothing` otherwise (including the
  "no candidates found" case, which is the common case for functions with
  no modulo-cons opportunity at all).
- `optimizePotentialTailCall` runs this pre-pass once per def and threads
  the `Maybe (ConsInfo, Index.ZeroBased)` result through to
  `optimizeTail` as an extra parameter, `consIdentity`.
- In `optimizeTail`, the existing `Can.Binop _ home name _ left right |
  isListCons home name` arm and a new `Can.Call (A.At _ (Can.VarCtor
  Can.Normal home name _ _)) args` arm both funnel through one shared
  helper, `tryModuloCons`, which:
  1. Confirms the call's own identity matches `consIdentity` (a
     belt-and-suspenders guard against a nested, non-tail-reachable
     occurrence that happens to structurally match but wasn't part of
     the pre-scan's tail-position walk).
  2. If it matches: optimizes every non-hole argument via the ordinary
     `optimize` function (in original field order), extracts the hole
     argument's rebind pairs via the existing `matchTailSelfCall`, and
     produces `Opt.TailCallCons consInfo holeIndex rootName otherFields
     rebinds`.
  3. If it doesn't match (disabled or the call site itself doesn't
     qualify — e.g. no direct self-call anywhere in its args): falls
     through to plain `optimize hints cycle locExpr`, producing an
     ordinary, unaccelerated constructor call.
- `hasTailCallCons`, `wrapConsBase`, `wrapConsBaseDecider` need no
  structural changes — they pattern-match on the `Opt.TailCallCons` /
  `Opt.TailCallConsBase` shape itself, not on payload contents, so the
  extra fields simply come along.
- `toTailDef` passes the single agreed `(ConsInfo, Index.ZeroBased, arity)`
  (from `consIdentity`, when present) into `Opt.TailDefCons`.

## Codegen changes (`Generate.JavaScript.Expression` / `.Name` / `.hs`)

- New helper:
  ```haskell
  generateConsCell
    :: Mode.Mode -> ConsInfo -> Index.ZeroBased
    -> [(Index.ZeroBased, JS.Expr)] -> JS.Expr -> JS.Expr
  ```
  builds one cell: for `ConsKernel`, reproduces today's exact
  `_List_Cons(head, holeValue)` call; for `ConsCtor global arity`, calls
  `JS.Call (JS.Ref (JsName.fromGlobal home name))` with an
  `arity`-length argument list assembled by placing each `(index, value)`
  from the other-fields list at its position and `holeValue` at
  `holeIndex`.
- `generateTailCallCons`, `generateTailCallConsBase`,
  `generateTailDefCons` each gain a `ConsInfo` + hole-index parameter and
  call `generateConsCell` instead of hardcoding `_List_Cons`/`listNil`.
  `mcHoleField` becomes `JsName.fromIndex holeIndex` computed per-def
  (still one value threaded through all three functions for a given def,
  per the "one hole index per function" restriction above), rather than
  the current hardcoded constant `Index.second`.
- Sentinel creation in `generateTailDefCons`: for `ConsKernel`, unchanged
  (`_List_Cons(null, _List_Nil)`); for `ConsCtor`, calls the ctor's
  constructor function with `arity` `JS.Null` arguments — all discarded,
  since only `start[holeField]` is ever read back once the loop
  terminates.
- `Generate/JavaScript.hs` (`generateCycleFunc`'s `TailDefCons` case),
  `Generate/Mode.hs` (`findDefArity` / `addCycleFunc` / `scanDef`
  exhaustiveness), `Nitpick/Debug.hs` (`hasDebug` / `defHasDebug`) —
  same mechanical threading as V1, now passing the extra `ConsInfo` /
  index fields through.
- Interaction with ADT shape padding (`b8befd98`): a `ConsCtor` cell's
  hole field is always a genuine declared field of that union (never a
  padding field, since `holeIndex < arity` by construction), so mutation
  targets a real field regardless of Prod-mode padding. Expected to need
  no code changes; verified explicitly in the plan below rather than
  assumed.
- Dev vs. Prod: TRMC stays mode-independent, as V1 established (it runs
  in the `Optimize` phase, before `Generate.Mode` distinguishes Dev/Prod).
  `Debug.toString`/debugger never see the sentinel — it never escapes,
  only `start[holeField]` is returned once fully mutated — identical
  reasoning to V1's Dev-mode verification.

## Examples

**Binary tree, right-leaning recursion (the motivating case):**

```elm
type Tree = Leaf | Node Tree Int Tree

buildRight : Int -> Int -> Tree
buildRight n end =
    if n > end then
        Leaf
    else
        Node Leaf n (buildRight (n + 1) end)
```

`detectConsIdentity` finds one candidate: `ConsCtor (Global Main "Node") 3`
at hole index 2 (the third argument, `buildRight (n + 1) end`, is the only
direct self-call). `Leaf` is `Can.Normal` here too — `Can.Enum` only
applies when *every* constructor in a union is 0-arity
(`Canonicalize/Environment/Local.hs:348`), and `Tree` mixes `Leaf` (0) with
`Node` (3) — so `Leaf` is a plain 0-arity `Can.Normal` value reference,
handled as an ordinary base case and wrapped into `TailCallConsBase` by
`wrapConsBase` exactly like any other non-recursive leaf. Compiles to:

```js
function buildRight(n, end) {
  var $start = Main$Node(null, null, null);
  var $end = $start;
  buildRight: while (true) {
    if (n > end) {
      $end.c = Main$Leaf;
      return $start.c;
    } else {
      var $cell = Main$Node(Main$Leaf, n, null);
      $end.c = $cell;
      $end = $cell;
      var $temp$n = n + 1;
      n = $temp$n;
      continue buildRight;
    }
  }
}
```

**Two-sided recursion, only one side accelerated:**

```elm
mirror : Tree -> Tree
mirror tree =
    case tree of
        Leaf -> Leaf
        Node l v r -> Node (mirror r) v (mirror l)
```

Here `mirror r` (first argument) and `mirror l` (third argument) are both
self-calls. The rightmost, `mirror l`, becomes the accelerated hole;
`mirror r` (first argument) compiles as an ordinary, non-tail recursive
`Opt.Call` — evaluated eagerly before the cell is built, exactly as
today, still bounded by JS stack depth on that side, but correct.

## Testing / verification

No automated suite exists in this repo (per `CLAUDE.md`) — verification
follows the same manual protocol used for prior perf commits:

1. Build the compiler in the Docker toolchain (`-O0` for the iterate
   loop), with a **fresh** `ELM_HOME` volume (this is another `.elmo`
   format change).
2. Write a scratch `.elm` module covering: the `buildRight` case above
   (single-sided recursion, hole not at the last field position — field
   index 2 of 3, but exercising the "any position" detection since it's
   the *last* syntactic argument here; also add a variant with the hole
   in the *first* argument position to specifically exercise non-last-field
   detection), the `mirror` two-sided case (confirm only one side
   accelerates and output is still correct), a mixed-ctor case that
   should be **disqualified** (confirm it falls back to unaccelerated
   recursion, not a crash or wrong output), and the existing List
   `myMap` scratch test (confirm `ConsKernel` output is unchanged from
   V1, byte-for-byte).
3. Compile with `elm make --optimize`; inspect emitted JS for the
   expected sentinel/loop structure per case.
4. Compile the same modules in Dev mode; confirm sentinel never leaks
   into `Debug.toString` output and structure matches the Prod-mode
   field layout (same field names, no padding).
5. Run under Node: correctness via checksum/structural comparison
   (in-order traversal or value sum) between this change's output and a
   hand-reverted / baseline-compiled naive-recursive version, across
   several tree sizes.
6. **Robustness benchmark:** find today's stack-overflow threshold for
   `buildRight` (expect degenerate/right-leaning trees to crash in the
   same rough order of magnitude as List's ~6300-element finding), then
   confirm the new codegen builds a tree 10-100x larger with no crash.
7. **Speed benchmark:** interleaved process runs (`drive.sh`-style
   harness, `REPS` parameter for sub-ms sizes), Node/V8, sizes below
   today's stack limit, comparing against the naive-recursive baseline.
   Report median of several runs after warmup, with checksums confirmed
   identical, following the exact methodology in `memory/trmc-plan.md`'s
   List Nutzen-Check and `memory/adt-shape-padding-plan.md`'s benchmark
   notes (including the "fresh `ELM_HOME` on both sides" trap documented
   there).
8. Confirm no regression in the ADT shape padding interaction: diff the
   generated JS for a padded union with a `ConsCtor` hole field against
   an unpadded (hypothetical) version to confirm the hole field access
   path is identical modulo the padding fields themselves.
