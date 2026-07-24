# Function-Composition (`<<`/`>>`) Chain Flattening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flatten `f << g << h`/`f >> g >> h`-shaped composition chains (any length, either operator,
any associativity/parenthesization) into a single JS closure with no intermediate `composeL`/`composeR`
runtime calls, in `--optimize` (Prod) builds only.

**Architecture:** A new pair of functions in `Generate/JavaScript/Expression.hs` — `collectComposeSide`
(walks both operand positions of a saturated `composeL`/`composeR` call, recursing only into further
*saturated* 2-argument compose calls, returning an ordered flat list of terminal `Opt.Expr` leaves) and
`flattenCompose` (builds one `Opt.Function` wrapping a fold of plain JS calls over that leaf list, then
reuses the existing `generateJsExpr` machinery to render it) — wired into `generateBasicsCall`'s
existing `[elmLeft, elmRight]` dispatch arm, gated to `Mode.Prod`. No new `Opt.Expr` constructor, no
`.elmo`/binary-format change, no `Optimize.*` change — this is purely a `Generate.JavaScript` codegen
change, the same level the historical (2018, since-reverted) `decomposeL`/`decomposeR` lived at.

**Tech Stack:** Haskell (GHC 9.8.4 via the project's Docker toolchain).

## Global Constraints

- Build with `-Wall -Werror` (baked into `elm.cabal`) — any unused import/bind fails the build.
- No `.elmo`/`.elmi` binary format change — must not touch `AST.Optimized`'s `Data.Binary` instances
  (this plan doesn't add any new `Opt.Expr` constructor, so this is automatic as long as Task 1 stays
  within `Generate.JavaScript.Expression`).
- **`Mode.Prod`-only.** `Mode.Dev` output must be byte-identical before and after this change — Dev
  output is a contract for the debugger/time-travel tooling per `CLAUDE.md`. Verified explicitly in
  Task 2.
- Full design rationale, the historical bug's exact root cause (traced against this repo's current
  code, not just the upstream issue text), and the argument for why this design avoids it *by
  construction*: `docs/superpowers/specs/2026-07-24-compose-chain-flattening-design.md` — read it
  before starting.
- Only `composeL`/`composeR` calls with **exactly 2 arguments** are ever intercepted. An under-saturated
  operand (e.g. `(<<) Just` — the exact historical regression shape) is deliberately left as an opaque
  leaf, compiled by the ordinary, unmodified codegen path. Do not attempt to special-case it further in
  this plan — see the design spec's "Root cause" section for why that specific shape is the dangerous
  one to touch.
- This does not touch `apply` (`Generate/JavaScript/Expression.hs:858-863`, still used unchanged by
  `apL`/`apR`) at all — the new code never calls it, by design.

---

### Task 1: Implement chain flattening in `Generate/JavaScript/Expression.hs`

**Files:**
- Modify: `compiler/src/Generate/JavaScript/Expression.hs`

**Interfaces:**
- Consumes: `Opt.Expr` (`Opt.Call`, `Opt.VarGlobal`, `Opt.Global`, `Opt.VarLocal`, `Opt.Function` —
  already imported qualified as `Opt`), `Name.Name` (already imported qualified as `Name`, with
  `OverloadedStrings` already enabled at the top of this file), `ModuleName.basics` (already imported
  qualified as `ModuleName`, already used elsewhere in this same file at line 884's `toSeqs`),
  `Mode.Mode`/`Mode.Prod` (already imported qualified as `Mode`), `generateJsExpr` (defined earlier in
  this same file).
- Produces: nothing consumed by later tasks in this plan — Task 2 only builds and runs the resulting
  compiler binary, it doesn't call any Haskell function from Task 1 directly.

- [ ] **Step 1: Add `composeParamName`, `collectComposeSide`, `flattenCompose`**

Find this existing code in `compiler/src/Generate/JavaScript/Expression.hs` (`generateBasicsCall`'s
final wildcard case, right before the `equal` helper):

```haskell
    _ ->
      generateGlobalCall home name (map (generateJsExpr mode) args)


equal :: JS.Expr -> JS.Expr -> JS.Expr
```

Insert a new block between them:

```haskell
    _ ->
      generateGlobalCall home name (map (generateJsExpr mode) args)


-- COMPOSITION CHAIN FLATTENING (Mode.Prod only)
--
-- See docs/superpowers/specs/2026-07-24-compose-chain-flattening-design.md
-- for the full derivation, including the historical (2018, since-reverted)
-- decomposeL/decomposeR bug this deliberately avoids.
--
-- Collision-free with every other internal-use name in this file (record-
-- update temp, ctor tag field, generic partial-application currying all use
-- the bare "$") -- `$` cannot appear in a real Elm identifier, same
-- invariant Name.hs's makeMCStart/makeMCCell/etc. already rely on.
composeParamName :: Name.Name
composeParamName =
  "$compose$"


-- Flattens one operand of a composeL/composeR call into an ordered
-- ("outermost function first") list of terminal leaves. Only unfolds a
-- SATURATED (exactly 2-argument) composeL/composeR call any further -- an
-- under-saturated operand like `(<<) Just` (1 argument) is a single opaque
-- leaf, left to the ordinary, unmodified call-codegen path. This is what
-- keeps the historical apply-based resaturation bug from being possible:
-- terminal leaves are never re-assembled into a new saturated composeL/
-- composeR call the way the old `apply`-based fold did.
collectComposeSide :: Opt.Expr -> [Opt.Expr]
collectComposeSide expr =
  case expr of
    Opt.Call (Opt.VarGlobal (Opt.Global home "composeL")) [left, right]
      | home == ModuleName.basics ->
          collectComposeSide left ++ collectComposeSide right

    Opt.Call (Opt.VarGlobal (Opt.Global home "composeR")) [left, right]
      | home == ModuleName.basics ->
          collectComposeSide right ++ collectComposeSide left

    _ ->
      [expr]


-- Entry point, called from generateBasicsCall's [elmLeft, elmRight] arm
-- with `name` already known to be "composeL" or "composeR" and exactly 2
-- arguments present (so this always collects at least 2 leaves total).
-- Builds one Opt.Function around one fresh parameter shared by the whole
-- chain, then hands off to the ordinary, unmodified generateJsExpr/
-- generateFunction path -- no new JS-codegen machinery, only new Opt.Expr
-- construction.
flattenCompose :: Mode.Mode -> Name.Name -> Opt.Expr -> Opt.Expr -> JS.Expr
flattenCompose mode op elmLeft elmRight =
  let
    leaves =
      if op == "composeL" then
        collectComposeSide elmLeft ++ collectComposeSide elmRight
      else
        collectComposeSide elmRight ++ collectComposeSide elmLeft

    body =
      foldr (\leaf acc -> Opt.Call leaf [acc]) (Opt.VarLocal composeParamName) leaves
  in
  generateJsExpr mode (Opt.Function [composeParamName] body)
```

- [ ] **Step 2: Wire the two new dispatch guards**

Find this existing code in the same file (`generateBasicsCall`'s `[elmLeft, elmRight]` arm):

```haskell
    [elmLeft, elmRight] ->
      case name of
        -- NOTE: removed "composeL" and "composeR" because of this issue:
        -- https://github.com/elm/compiler/issues/1722
        "append"   -> append mode elmLeft elmRight
```

Replace just those 4 lines with:

```haskell
    [elmLeft, elmRight] ->
      case name of
        "composeL" | Mode.Prod _ _ <- mode -> flattenCompose mode name elmLeft elmRight
        "composeR" | Mode.Prod _ _ <- mode -> flattenCompose mode name elmLeft elmRight
        "append"   -> append mode elmLeft elmRight
```

(Everything else in this arm — `"apL"`, `"apR"`, the trailing `_ -> let left = ...; right = ...`
block with its own nested `case name of ...` — is unchanged. In `Mode.Dev`, `"composeL"`/`"composeR"`
now simply fail their guard and fall through to that unchanged trailing `_` alternative exactly as
today, ending at `generateGlobalCall home name [left, right]` — identical Dev output to before this
change.)

- [ ] **Step 3: Build the compiler and confirm it compiles clean under `-Wall -Werror`**

```bash
cd /home/andre/Workspace/Projects/Freinet/elm-compiler
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds (exit code 0), no warnings/errors mentioning `Generate/JavaScript/Expression.hs`.

- [ ] **Step 4: Commit**

```bash
git add compiler/src/Generate/JavaScript/Expression.hs
git commit -m "perf: flatten composeL/composeR chains into a single closure (Prod only)"
```

---

### Task 2: Verify against a real compiler build (structure, historical regression, Dev parity, timing)

**Files:**
- None in the repo — this task only creates scratch artifacts outside the repo (per `CLAUDE.md`: "Use
  a disposable scratch project, not a real one in this repo").

**Interfaces:**
- Consumes: the `elm` binary built in Task 1 (found via `cabal list-bin elm` inside the Docker
  toolchain); the pre-Task-1 commit hash as the "before" reference build (run `git log --oneline -2`
  at execution time to get the exact hash, since this plan doesn't know it in advance).
- Produces: nothing consumed by later tasks — this is the terminal verification task for this plan.

**Binary portability note:** the `elm` binary `cabal build` produces is dynamically linked against the
`haskell:9.8.4` image's libraries — do not copy it out and run it directly on the host. Every
invocation of the compiler binary below runs inside a `haskell:9.8.4` container (the binary
bind-mounted read-only). Only the *compiled JS output* (`node ...`) runs directly on the host.

- [ ] **Step 1: Build the "before" reference binary from the pre-Task-1 commit**

```bash
BEFORE_SHA=$(git log --oneline -2 --format=%H | tail -1)
git worktree add /tmp/elm-compose-flatten-before "$BEFORE_SHA"
mkdir -p /tmp/elm-compose-flatten-bin
docker run --rm -v /tmp/elm-compose-flatten-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-compose-flatten-before:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal build elm --ghc-options=-O0 2>&1 | tail -n 40; exit ${PIPESTATUS[0]}'
docker run --rm -v /tmp/elm-compose-flatten-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-compose-flatten-before:/work/dist-newstyle \
  -v /tmp/elm-compose-flatten-bin:/bin-out \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /bin-out/elm-before'
```

Expected: `/tmp/elm-compose-flatten-bin/elm-before` exists.

- [ ] **Step 2: Copy the "after" binary (from Task 1) out to the same stable path**

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
docker run --rm -v "$REPO_ROOT":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  -v /tmp/elm-compose-flatten-bin:/bin-out \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /bin-out/elm-after'
```

Expected: `/tmp/elm-compose-flatten-bin/elm-after` exists. Nothing written inside the repo checkout.

- [ ] **Step 3: Create the scratch project**

**Critical: use two separate project directories, one per compiler binary — never compile "before"
and "after" into the same directory.** `elm make` writes a project-local build cache to
`<project>/elm-stuff/`, keyed only on the *source file's* content, not on which compiler binary
produced it. Compiling "before" and "after" into the same directory in sequence lets the second
`elm make` call silently reuse the first binary's already-compiled output — with no error, no warning,
no exit-code signal. This exact failure mode already happened once in this fork's own history (see
`docs/superpowers/specs/2026-07-21-spike-runbook.md`, Section 7) and again during the array-chain-
fusion plan's own verification. `after-prod.js` and `after-dev.js` may safely share one directory
(same binary compiling twice); `before-prod.js` must use a separate one.

The `fromMaybe`/`extractOrZero`/`fromMaybeUse` trio below reproduces the exact historical regression
shape from `elm/compiler#1722` (`f << (<<) Just`), concretely instantiated so it's a checkable `Int ->
Int` function: `fromMaybe extractOrZero addOne` unfolds to `extractOrZero (Just << addOne)` =
`\seed -> Maybe.withDefault 0 (Just (addOne seed))` = `\seed -> addOne seed`, i.e. `fromMaybeUse n`
must equal `n + 1` for every `n`.

```bash
mkdir -p /tmp/elm-compose-flatten-bench-after/src /tmp/elm-compose-flatten-bench-before/src
cat > /tmp/elm-compose-flatten-bench-after/elm.json <<'EOF'
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": { "elm/core": "1.0.5" },
        "indirect": {}
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
EOF
cp /tmp/elm-compose-flatten-bench-after/elm.json /tmp/elm-compose-flatten-bench-before/elm.json
cat > /tmp/elm-compose-flatten-bench-after/src/Bench.elm <<'EOF'
module Bench exposing (main)

import Maybe
import Platform


addOne : Int -> Int
addOne x =
    x + 1


double : Int -> Int
double x =
    x * 2


negate_ : Int -> Int
negate_ x =
    -x


square : Int -> Int
square x =
    x * x


chain2L : Int -> Int
chain2L =
    addOne << double


chain3L : Int -> Int
chain3L =
    addOne << double << negate_


chain4L : Int -> Int
chain4L =
    addOne << double << negate_ << square


chain2R : Int -> Int
chain2R =
    addOne >> double


chain3R : Int -> Int
chain3R =
    addOne >> double >> negate_


chain4R : Int -> Int
chain4R =
    addOne >> double >> negate_ >> square


parenLeftL : Int -> Int
parenLeftL =
    (addOne << double) << negate_


extractOrZero : (Int -> Maybe Int) -> Int -> Int
extractOrZero decoder seed =
    Maybe.withDefault 0 (decoder seed)


fromMaybe : ((a -> Maybe b) -> c) -> (a -> b) -> c
fromMaybe f =
    f << (<<) Just


fromMaybeUse : Int -> Int
fromMaybeUse =
    fromMaybe extractOrZero addOne


type alias Model =
    { chain2L : Int -> Int
    , chain3L : Int -> Int
    , chain4L : Int -> Int
    , chain2R : Int -> Int
    , chain3R : Int -> Int
    , chain4R : Int -> Int
    , parenLeftL : Int -> Int
    , fromMaybeUse : Int -> Int
    }


main : Program () Model ()
main =
    Platform.worker
        { init =
            \_ ->
                ( { chain2L = chain2L
                  , chain3L = chain3L
                  , chain4L = chain4L
                  , chain2R = chain2R
                  , chain3R = chain3R
                  , chain4R = chain4R
                  , parenLeftL = parenLeftL
                  , fromMaybeUse = fromMaybeUse
                  }
                , Cmd.none
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
EOF
cp /tmp/elm-compose-flatten-bench-after/src/Bench.elm /tmp/elm-compose-flatten-bench-before/src/Bench.elm
```

Note: `main`'s `Model` holds every benchmarked function so Prod-mode dead-code elimination (a
reachability graph over top-level definitions) keeps them all present in the compiled output even
though `init` never calls them, matching every prior fusion plan's own fixture convention in this
fork.

- [ ] **Step 4: Compile with both binaries, expose internals for direct invocation**

```bash
docker run --rm \
  -v /tmp/elm-compose-flatten-bench-after:/test \
  -v /tmp/elm-compose-flatten-bin/elm-after:/usr/local/bin/elm:ro \
  -v elm-compose-flatten-home-after:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --optimize --output=after-prod.js'

docker run --rm \
  -v /tmp/elm-compose-flatten-bench-before:/test \
  -v /tmp/elm-compose-flatten-bin/elm-before:/usr/local/bin/elm:ro \
  -v elm-compose-flatten-home-before:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --optimize --output=before-prod.js'

docker run --rm \
  -v /tmp/elm-compose-flatten-bench-after:/test \
  -v /tmp/elm-compose-flatten-bin/elm-after:/usr/local/bin/elm:ro \
  -v elm-compose-flatten-home-after:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --output=after-dev.js'

docker run --rm \
  -v /tmp/elm-compose-flatten-bench-before:/test \
  -v /tmp/elm-compose-flatten-bin/elm-before:/usr/local/bin/elm:ro \
  -v elm-compose-flatten-home-before:/root/.elm \
  haskell:9.8.4 bash -c 'cd /test && elm make src/Bench.elm --output=before-dev.js'

python3 - <<'PYEOF'
for path in ["/tmp/elm-compose-flatten-bench-after/after-prod.js",
             "/tmp/elm-compose-flatten-bench-before/before-prod.js",
             "/tmp/elm-compose-flatten-bench-after/after-dev.js",
             "/tmp/elm-compose-flatten-bench-before/before-dev.js"]:
    with open(path) as f:
        content = f.read()
    marker = "_Platform_export("
    idx = content.rfind(marker)
    expose = """
scope.__chain2L = $author$project$Bench$chain2L;
scope.__chain3L = $author$project$Bench$chain3L;
scope.__chain4L = $author$project$Bench$chain4L;
scope.__chain2R = $author$project$Bench$chain2R;
scope.__chain3R = $author$project$Bench$chain3R;
scope.__chain4R = $author$project$Bench$chain4R;
scope.__parenLeftL = $author$project$Bench$parenLeftL;
scope.__fromMaybeUse = $author$project$Bench$fromMaybeUse;
"""
    content = content[:idx] + expose + content[idx:]
    with open(path, "w") as f:
        f.write(content)
    print(f"patched {path}")
PYEOF
```

Expected: all four files patched without error (the `$author$project$Bench$...` names are stable
across Dev/Prod — only record *field* names get shortened in Prod, not global function names).

- [ ] **Step 5: Structural check — flattened chains have zero `composeL`/`composeR` calls; the
  historical-regression case has exactly one (the legitimately-unresolvable under-saturated part)**

Note: the check targets `fromMaybe` (not `fromMaybeUse`) for the regression case — `fromMaybe f = f
<< (<<) Just` is where the actual composition expression lives in the source; `fromMaybeUse = fromMaybe
extractOrZero addOne` is just a 2-argument call site to it (`A2($author$project$Bench$fromMaybe, ...)`
in the compiled output), containing no `composeL`/`composeR` reference of its own to search for.

The extraction below bounds each top-level definition's compiled text by the *next* top-level
`$author$project$Bench$...` declaration (or `_Platform_export(` for the last one) rather than by
brace-matching — robust regardless of exactly how each function's body is bracketed/indented.

```bash
python3 - <<'PYEOF'
import re
with open("/tmp/elm-compose-flatten-bench-after/after-prod.js") as f:
    content = f.read()

def extract_var_block(name):
    start_marker = f"$author$project$Bench${name} = "
    start = content.index(start_marker) + len(start_marker)
    next_var = content.find("\nvar $author$project$Bench$", start)
    next_export = content.find("_Platform_export(", start)
    end = min(c for c in (next_var, next_export) if c != -1)
    return content[start:end]

for name in ["chain2L", "chain3L", "chain4L", "chain2R", "chain3R", "chain4R", "parenLeftL"]:
    body = extract_var_block(name)
    n = len(re.findall(r"\$elm\$core\$Basics\$compose[LR]\b", body))
    print(f"{name}: composeL/R call count = {n}")
    assert n == 0, f"expected fully flattened (0 composeL/R calls) in {name}, got {n}"

fm_body = extract_var_block("fromMaybe")
n_fm = len(re.findall(r"\$elm\$core\$Basics\$compose[LR]\b", fm_body))
print(f"fromMaybe: composeL/R call count = {n_fm}")
assert n_fm == 1, f"expected exactly 1 composeL/R call (the under-saturated (<<) Just part, left unfused by design), got {n_fm}"

print("OK: structural checks passed")
PYEOF
```

Expected: prints `OK: structural checks passed`. (`fromMaybe` having exactly 1 remaining
`composeL`/`composeR` call — not 0 — is the *expected*, by-design outcome: the design spec's "Root
cause" section explains why `(<<) Just` is deliberately left as an opaque leaf rather than further
unfolded. Concretely: `fromMaybe`'s body flattens to `function (f) { return function ($compose$) {
return f($elm$core$Basics$composeL(Just)($compose$)); }; }` — the outer `f << X` layer is fully
flattened away, while `X = (<<) Just` itself, being under-saturated, still goes through one real
`composeL` call, exactly as the design intends.)

- [ ] **Step 6: Correctness — before vs. after, across all benchmarked functions and a range of inputs**

```bash
cat > /tmp/elm-compose-flatten-bench-after/check.js <<'EOF'
const before = require('/tmp/elm-compose-flatten-bench-before/before-prod.js');
const after = require('/tmp/elm-compose-flatten-bench-after/after-prod.js');

let failures = 0;
const fns = ['chain2L', 'chain3L', 'chain4L', 'chain2R', 'chain3R', 'chain4R', 'parenLeftL', 'fromMaybeUse'];
for (const n of [-1000, -7, -1, 0, 1, 2, 7, 1000]) {
  for (const fn of fns) {
    const bResult = before[`__${fn}`](n);
    const aResult = after[`__${fn}`](n);
    if (bResult !== aResult) {
      console.log(`MISMATCH ${fn}(${n}): before=${bResult} after=${aResult}`);
      failures++;
    }
  }
}
// The historical-regression function's own closed-form check, independent of the "before" binary:
// fromMaybeUse(n) must equal n + 1 for every n (see Step 3's derivation).
for (const n of [-1000, -7, -1, 0, 1, 2, 7, 1000]) {
  const result = after.__fromMaybeUse(n);
  if (result !== n + 1) {
    console.log(`fromMaybeUse(${n}) = ${result}, expected ${n + 1}`);
    failures++;
  }
}
if (failures === 0) {
  console.log('ALL RESULTS MATCH');
} else {
  console.log(`${failures} MISMATCHES`);
  process.exit(1);
}
EOF
node /tmp/elm-compose-flatten-bench-after/check.js
```

Expected: prints `ALL RESULTS MATCH`.

- [ ] **Step 7: Dev-mode parity — output must be byte-identical before and after this change**

```bash
diff /tmp/elm-compose-flatten-bench-before/before-dev.js /tmp/elm-compose-flatten-bench-after/after-dev.js
echo "diff exit code: $?"
```

Expected: no output from `diff`, exit code `0`. (Both files were compiled from the identical
`Bench.elm` source with different binaries; any difference here would mean this change leaked into
`Mode.Dev`, violating the Global Constraints above — if this fails, re-check that Task 1's Step 2 used
`| Mode.Prod _ _ <- mode` guards, not an unconditional dispatch.)

- [ ] **Step 8: Interleaved timing — confirm the real compiler reproduces the research phase's speedup range**

```bash
mkdir -p /tmp/elm-compose-flatten-timing
cat > /tmp/elm-compose-flatten-timing/run-one.js <<'EOF'
const [,, variant, fnName, repsStr] = process.argv;
const m = require(variant === 'before' ? '/tmp/elm-compose-flatten-bench-before/before-prod.js' : '/tmp/elm-compose-flatten-bench-after/after-prod.js');
const REPS = Number(repsStr);
const fn = m[`__${fnName}`];
let result;
for (let i = 0; i < Math.max(3, Math.floor(REPS / 20)); i++) result = fn(i % 1000);
const start = process.hrtime.bigint();
for (let i = 0; i < REPS; i++) result = fn(i % 1000);
const end = process.hrtime.bigint();
console.log(JSON.stringify({ variant, fnName, REPS, ms: Number(end - start) / 1e6, lastResult: result }));
EOF

for fn in chain2L chain3L chain4L chain2R chain3R chain4R; do
  echo "=== $fn ==="
  node /tmp/elm-compose-flatten-timing/run-one.js before "$fn" 20000000
  node /tmp/elm-compose-flatten-timing/run-one.js after "$fn" 20000000
  node /tmp/elm-compose-flatten-timing/run-one.js before "$fn" 20000000
  node /tmp/elm-compose-flatten-timing/run-one.js after "$fn" 20000000
done
```

Expected: for each chain, `after`'s `ms` is lower than `before`'s in both interleaved repetitions, and
`lastResult` identical between `before`/`after` at matching `fnName` (correctness re-confirmation under
the timing harness itself). The gap should be in the same rough neighborhood the research phase's
hand-patch microbenchmarks found (roughly 2x-5x, growing with chain length) — exact numbers will differ
from the hand-patch spike since the real compiler's generated code isn't textually identical to the
hand-simulated version, but `after` must beat `before` at every chain length tested, and the 2-function
chains should show the smallest gap, 4-function chains the largest.

**If this instead shows `after` at parity with or slower than `before`:** before concluding the
optimization has no real effect, re-run Step 5's structural check against `before-prod.js` specifically
(swap the file path). If `before`'s `chain4L` body already shows `composeL/R call count = 0`, the two
binaries were never actually compared — see `docs/superpowers/specs/2026-07-21-spike-runbook.md`
Section 7 for this exact failure mode and its fix (separate project directories, already applied in
Steps 3-4 above as written).

- [ ] **Step 9: Clean up scratch artifacts**

```bash
git worktree remove /tmp/elm-compose-flatten-before --force
docker volume rm elm-dist-compose-flatten-before
docker volume rm elm-compose-flatten-home-before
docker volume rm elm-compose-flatten-home-after
rm -rf /tmp/elm-compose-flatten-bench-before /tmp/elm-compose-flatten-bench-after /tmp/elm-compose-flatten-bin /tmp/elm-compose-flatten-timing
```

No commit for this task — it's verification only, produces no repo changes.
