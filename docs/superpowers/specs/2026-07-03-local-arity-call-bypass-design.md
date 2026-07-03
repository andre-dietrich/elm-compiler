# Local/lambda direct-call bypass — design

Date: 2026-07-03

## Context

This fork already bypasses the generic `A2..A9` arity-dispatch helpers for
**known-arity calls to top-level globals** (`be2c061f`): when a call site
statically supplies exactly as many arguments as a global definition's
arity, codegen emits a direct `.f(...)` call instead of routing through
`A2..A9`. This monomorphizes the call site for the JS engine and skips a
runtime arity check that's already known at compile time. The same
technique was later extended to unwrap higher-order-function callback
parameters (`2d47134d`).

That bypass only fires for `Opt.VarGlobal` (see
`Generate/JavaScript/Expression.hs:468`, guarded by
`Mode.lookupArity`/`Generate/Mode.hs:80-90`). Calls to **local**
`let`-bound named functions — a very common idiom for loop helpers, small
predicates reused a few times, and parser/state-machine-style code — still
always go through `A2..A9`, even though their arity is just as statically
obvious from the binding site.

This design extends the existing mechanism to cover that case.

## Scope

Applies only in `Mode.Prod` (consistent with all prior perf work; `Mode.Dev`
output is a debugger/`Debug.toString` contract and must never change — see
`CLAUDE.md`).

Target pattern, in `AST.Optimized`:

```haskell
Opt.Let (Opt.Def name (Opt.Function args body)) rest
Opt.Let (Opt.TailDef name args body) rest
Opt.Let (Opt.TailDefCons name args body) rest
```

A later `Opt.Call (Opt.VarLocal name) callArgs` — either inside `body`
itself (local recursion) or in `rest` — where `length callArgs == length
args`, is rewritten from an `A2..A9(name, ...)` call to a direct
`name.f(...)` call.

**Out of scope for v1** (see "Deliberate v1 limitation" below):
- Destructured function values (e.g. `let (f, g) = (fn1, fn2) in ...`) —
  arity isn't syntactically visible at the binding site without deeper
  analysis of the RHS.
- Forward references and true mutual recursion between local `let`-peers
  (a call from `f`'s own body to a sibling defined *later* in the same
  `let` chain, before that sibling's arity has been recorded).
- Anonymous lambda literals applied inline and callback parameters of the
  enclosing definition — explicitly excluded per scoping decision; only
  named `let`-bindings are covered.
- Skipping the `F2..F9` wrapper allocation at the definition site. The
  wrapper is still always allocated; only the *call sites* that know the
  arity skip `A2..A9` and call `.f` directly. Removing the wrapper
  allocation itself would require an escape analysis (proving the local
  name is never used as a bare value anywhere in its scope) — a
  meaningfully riskier follow-up, deliberately deferred.

## Safety property

This is a pure call-site rewrite over information already syntactically
visible at that point in the `Let` chain. Any binding shape not
specifically handled (the "out of scope" cases above) simply falls through
to today's existing `A2..A9` path, unchanged. There is no new failure
mode: worst case is a missed optimization, never incorrect output.

## Mechanism

Threaded the same way `Mode.setRawLocal`/`lookupRawLocal` already threads
the single raw-callback-parameter case for unwrapped HOFs
(`Generate/Mode.hs:117-129`):

- Extend `Arities` (`Generate/Mode.hs`) with a third map:
  `_localArities :: Map.Map Name.Name Int`.
- Add `Mode.addLocalArity :: Name.Name -> Int -> Mode -> Mode` — no-op in
  `Dev`, same pattern as `setRawLocal` — and
  `Mode.lookupLocalArity :: Mode -> Name.Name -> Maybe Int`.
- In the `Opt.Let` codegen case (`Generate/JavaScript/Expression.hs`), when
  the bound `Def` is `Def name (Function args _)` / `TailDef name args _`
  / `TailDefCons name args _`, generate **both** that def's own body and
  the `rest` continuation using `Mode.addLocalArity name (length args)
  mode` in place of the bare `mode`.
- In `generateCall`, add a branch alongside the existing `Opt.VarGlobal`
  check: `Opt.VarLocal name | Just arity <- Mode.lookupLocalArity mode
  name, arity == length args -> ...` emits a direct `.f` call, matching
  the shape of the existing global-arity branch.

### Deliberate v1 limitation — sequential visibility only

Because the arity map is threaded top-down and extended one `Let` at a
time, a call from `f`'s own body to a sibling defined *later* in the same
`let` block (forward reference or true mutual recursion between two local
closures) won't see that sibling's arity yet, and keeps using `A2..A9` —
correct, just not accelerated. This mirrors how TRMC V1 scoped down to
Kernel `::` only before generalizing: ship the common case (sequential
helper definitions, self-recursion via `TailDef`/`TailDefCons`) first,
treat full mutual-peer visibility as a possible follow-up only if it turns
out to matter in practice.

Shadowing is handled for free: each recursive `generate` call receives its
own extended `Mode` value (no mutation), so returning to an outer scope
after a `rest` branch automatically reverts to the outer map, and an inner
`let` reusing an outer name simply overwrites the map entry for its own
subtree.

## Examples

**Case A — plain local helper, called directly twice:**

```elm
validate a b c =
  let
    check x y = x > 0 && y > 0
  in
  if check a b then check b c else False
```

Today: `var check = F2(function(x,y){...}); ... A2(check,a,b) ... A2(check,b,c)`

After: definition unchanged; calls become `check.f(a,b)` / `check.f(b,c)`.

**Case B — kicking off a `TailDef` loop from outside its own body:**

```elm
sumList list =
  let
    go acc xs = case xs of
      [] -> acc
      x :: rest -> go (acc + x) rest
  in
  go 0 list
```

`go`'s internal recursive calls already compile to a `while`/`continue`
loop via the existing `TailCall` mechanism — untouched by this change. But
the one-time *entry* call `go 0 list` from `rest` currently still goes
through `A2(go, 0, list)` even though `go`'s arity is known right at its
own binding. This closes that gap too, for free — `TailDef`/`TailDefCons`
feed the same `_localArities` map as plain `Def`, so no special-casing is
needed between "plain local function" and "local tail-recursive loop."

## Testing / verification

No automated suite exists in this repo (per `CLAUDE.md`) — verification
follows the same manual protocol used for prior perf commits:

1. Build the compiler in the Docker toolchain (`-O0` for the iterate loop).
2. Write a scratch `.elm` module exercising: the plain-local-helper case
   (Case A), the `TailDef`-entry-call case (Case B), a shadowing case, and
   a forward-reference case (to confirm the v1 fallback is silent and
   correct, not broken).
3. Compile with `elm make --optimize`; inspect the emitted JS for the
   expected `.f(...)` direct calls, and confirm the forward-reference case
   still emits `A2(...)` (correct fallback, not a regression).
4. Compile the same module in Dev mode (no `--optimize`) and confirm the
   output is byte-identical to a pre-change build — the hard invariant
   from `CLAUDE.md`. Since `addLocalArity`/`lookupLocalArity` are no-ops in
   `Dev`, this should hold structurally; confirm by diff anyway.
5. Run the compiled JS under Node to confirm behavior is unchanged.
6. Optional: benchmark a hot local helper (e.g. inside a loop-heavy
   function) for a rough before/after number, in the spirit of the `1.3x
   sortWith` figure recorded for the compare/min/max work.
