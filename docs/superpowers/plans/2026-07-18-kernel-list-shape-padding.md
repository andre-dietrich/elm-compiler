# Kernel-List Shape Padding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make V8 see one monomorphic hidden class for kernel `List` (`Cons`/`Nil`) in `Mode.Prod` output, by padding `_List_Nil` to the same `{ $, a, b }` shape as `_List_Cons`, matching what `b8befd98` already does for Elm-defined ADT unions.

**Architecture:** `AST.Optimized.addKernel` bundles all of `List.js` into one `Opt.Kernel` graph node keyed by `Opt.toKernelGlobal "List"`. `Generate.JavaScript`'s `addGlobalHelp` already special-cases this node (the `Opt.Kernel` branch, `isDebugger` check). Add one pure helper, `padListNil`, that appends a single reassignment statement (`_List_Nil = { $: 0, a: null, b: null };`) right after that node's emitted text, gated on `Mode.Prod` and on the global being the `List` kernel node. No new AST constructor, no `.elmo` binary format change — this is pure `Generate`-time text concatenation.

**Tech Stack:** Haskell (GHC 9.8.4 via the project's Docker toolchain), `Data.ByteString.Builder`.

## Global Constraints

- `Mode.Prod`-specific codegen must never change `Mode.Dev` output (CLAUDE.md contract — Dev output backs the debugger/time-travel tooling and `Debug.toString`).
- No `.elmo`/`.elmi` binary format change — this change must not touch `AST.Optimized`'s `Data.Binary` instances.
- No `elm/core` changes — the padding is injected entirely by this compiler at codegen time.
- Build with `-Wall -Werror` (baked into `elm.cabal`) — any unused import/bind fails the build.
- Full design rationale and correctness argument: `docs/superpowers/specs/2026-07-18-kernel-list-shape-padding-design.md`.

---

### Task 1: Implement `padListNil` and wire it into the `Opt.Kernel` branch

**Files:**
- Modify: `compiler/src/Generate/JavaScript.hs:222-226` (the `Opt.Kernel` case in `addGlobalHelp`)
- Modify: `compiler/src/Generate/JavaScript.hs` — add new `padListNil` function next to `isDebugger` (currently defined at line 274-276)

**Interfaces:**
- Consumes: `Opt.toKernelGlobal :: Name.Name -> Opt.Global` (already exported from `AST.Optimized`, already imported qualified as `Opt` in this module); `Mode.Mode` constructors `Mode.Dev`/`Mode.Prod` (already imported qualified as `Mode`); `OverloadedStrings` (already enabled via `{-# LANGUAGE OverloadedStrings #-}` at the top of the file, confirmed in use for `B.Builder` string literals like `"_UNUSED"` at line 389).
- Produces: `padListNil :: Mode.Mode -> Opt.Global -> B.Builder` — appended into the `Opt.Kernel` branch's emitted builder for every kernel node (a no-op `mempty` for every node except the `List` kernel node in Prod mode).

- [ ] **Step 1: Add the `padListNil` helper**

Add this function immediately after `isDebugger` (after line 276, before the `-- GENERATE CYCLES` section comment at line 280):

```haskell
padListNil :: Mode.Mode -> Opt.Global -> B.Builder
padListNil mode global =
  case mode of
    Mode.Prod _ _ | global == Opt.toKernelGlobal "List" ->
      "_List_Nil = { $: 0, a: null, b: null };"
    _ ->
      mempty
```

- [ ] **Step 2: Wire it into the `Opt.Kernel` branch**

In `addGlobalHelp`, change (lines 222-226):

```haskell
    Opt.Kernel chunks deps ->
      if isDebugger global && not (Mode.isDebug mode) then
        state
      else
        addKernel (addDeps deps state) (generateKernel mode chunks)
```

to:

```haskell
    Opt.Kernel chunks deps ->
      if isDebugger global && not (Mode.isDebug mode) then
        state
      else
        addKernel (addDeps deps state) (generateKernel mode chunks <> padListNil mode global)
```

- [ ] **Step 3: Build the compiler and confirm it compiles clean under `-Wall -Werror`**

Run (from the repo root):

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 120; exit ${PIPESTATUS[0]}'
```

Expected: build succeeds (exit code 0), no warnings/errors mentioning `Generate/JavaScript.hs`.

- [ ] **Step 4: Commit**

```bash
git add compiler/src/Generate/JavaScript.hs
git commit -m "perf: pad kernel List's _List_Nil to Cons's {\$,a,b} shape in Prod"
```

---

### Task 2: Verify Dev/Prod output, correctness, and the spike's benchmark result

**Files:**
- None in the repo — this task only creates scratch artifacts outside the repo (per CLAUDE.md: "Use a disposable scratch project, not a real one in this repo").

**Interfaces:**
- Consumes: the `elm` binary built in Task 1 (found via `cabal list-bin elm` inside the same Docker toolchain); the pre-Task-1 commit hash `1fb7b7a6` (current `HEAD` before Task 1's commit, per this repo's git log at plan-writing time) as the "before" reference build.
- Produces: nothing consumed by later tasks — this is the terminal verification task for this plan.

Elm's compiled output supports `require()` directly: `generate` in `Generate/JavaScript.hs` wraps everything as `(function(scope){...}(this));`, and under Node's CommonJS wrapper `this === module.exports` at a required module's top level, so `const { Elm } = require("./bench.js")` works without any DOM/vm stubbing — no need to touch `document` or `vm.createContext`.

- [ ] **Step 1: Build the "before" reference binary from the pre-change commit**

```bash
git worktree add /tmp/elm-kernel-list-padding-before 1fb7b7a6
docker run --rm -v /tmp/elm-kernel-list-padding-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-before:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal build elm --ghc-options=-O0 2>&1 | tail -n 40; exit ${PIPESTATUS[0]}'
docker run --rm -v /tmp/elm-kernel-list-padding-before:/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist-before:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /work/elm-before'
```

Expected: `/tmp/elm-kernel-list-padding-before/elm-before` exists (a statically-linked-enough binary usable via the same Docker image as the "after" build).

- [ ] **Step 2: Copy the "after" binary out to a stable path the same way**

```bash
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; cp $(cabal list-bin elm) /work/elm-after'
```

Expected: `elm-after` appears at the repo root (untracked — do not `git add` it; delete it in Step 8).

- [ ] **Step 3: Create the scratch project and shared `Worker.elm`**

```bash
mkdir -p /tmp/elm-kernel-list-padding-bench/src
cat > /tmp/elm-kernel-list-padding-bench/elm.json <<'EOF'
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
cat > /tmp/elm-kernel-list-padding-bench/src/Worker.elm <<'EOF'
port module Worker exposing (main)

import Array
import Dict
import Set


port output : Int -> Cmd msg


type alias Flags =
    { mode : String, n : Int }


sumShortLists : Int -> Int -> Int
sumShortLists n acc =
    if n <= 0 then
        acc

    else
        sumShortLists (n - 1) (acc + List.sum (List.range 1 5))


sumOneLongList : Int -> Int
sumOneLongList n =
    List.sum (List.range 1 n)


dictArraySetSanity : Int
dictArraySetSanity =
    let
        d =
            Dict.fromList (List.map (\i -> ( i, i * 2 )) (List.range 1 1000))

        a =
            Array.fromList (List.range 1 1000)

        s =
            Set.fromList (List.range 1 1000)
    in
    List.sum (Dict.values d) + Array.foldl (+) 0 a + List.sum (Set.toList s)


compute : Flags -> Int
compute flags =
    case flags.mode of
        "short" ->
            sumShortLists flags.n 0

        "long" ->
            sumOneLongList flags.n

        _ ->
            dictArraySetSanity


main : Program Flags () ()
main =
    Platform.worker
        { init = \flags -> ( (), output (compute flags) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
EOF
cat > /tmp/elm-kernel-list-padding-bench/run.js <<'EOF'
const { Elm } = require(process.argv[2]);
const app = Elm.Worker.init({ flags: { mode: process.argv[3], n: parseInt(process.argv[4], 10) || 0 } });
app.ports.output.subscribe((value) => {
  console.log(value);
});
EOF
```

- [ ] **Step 4: Compile with the "after" binary in `--optimize` and confirm exactly one padding statement**

```bash
cd /tmp/elm-kernel-list-padding-bench
"$OLDPWD/elm-after" make src/Worker.elm --optimize --output=after-prod.js
grep -c '_List_Nil = { \$: 0, a: null, b: null };' after-prod.js
```

Expected: prints `1`.

- [ ] **Step 5: Compile the same module in Dev mode and confirm the padding statement is absent**

```bash
"$OLDPWD/elm-after" make src/Worker.elm --output=after-dev.js
grep -c '_List_Nil = { \$: 0, a: null, b: null };' after-dev.js || true
```

Expected: prints `0` (`grep -c` reports zero matches; it may exit non-zero, hence `|| true`).

- [ ] **Step 6: Runtime correctness — Dict/Array/Set sanity and checksum match against the "before" build**

```bash
"$OLDPWD/elm-before" make src/Worker.elm --optimize --output=before-prod.js
node run.js ./after-prod.js sanity 0
node run.js ./before-prod.js sanity 0
node run.js ./after-prod.js short 1000
node run.js ./before-prod.js short 1000
node run.js ./after-prod.js long 1000
node run.js ./before-prod.js long 1000
```

Expected: each pair of `after`/`before` invocations for the same mode prints the identical integer checksum (structural equality — `Dict`/`Array`/`Set`'s internal use of `List` is unaffected by the padding, per the design doc's correctness argument).

- [ ] **Step 7: Interleaved timing comparison for the two spike scenarios**

First, confirm checksums still match at the actual benchmarked size (5,000,000), not just the quick `n=1000` check from Step 6:

```bash
node run.js ./after-prod.js short 5000000
node run.js ./before-prod.js short 5000000
node run.js ./after-prod.js long 5000000
node run.js ./before-prod.js long 5000000
```

Expected: the two `short` runs print the same checksum, and the two `long` runs print the same checksum (different from the `short` checksum — that's expected, they compute different things).

Then time 15 interleaved reps per scenario, discarding stdout since correctness was just confirmed above:

```bash
cat > /tmp/elm-kernel-list-padding-bench/timeit.sh <<'EOF'
#!/usr/bin/env bash
# $1 = js file, $2 = mode, $3 = n
t0=$(date +%s%N)
node run.js "$1" "$2" "$3" > /dev/null
t1=$(date +%s%N)
echo $(( (t1 - t0) / 1000000 ))
EOF
chmod +x timeit.sh

for i in $(seq 1 15); do
  echo -n "short after=" ; ./timeit.sh ./after-prod.js short 5000000
  echo -n "short before="; ./timeit.sh ./before-prod.js short 5000000
done

for i in $(seq 1 15); do
  echo -n "long after=" ; ./timeit.sh ./after-prod.js long 5000000
  echo -n "long before="; ./timeit.sh ./before-prod.js long 5000000
done
```

Expected, matching the hand-patch spike (memory `kernel-list-padding-spike`): averaging each series, `short after` ~8% lower than `short before`; `long after` within noise (~0%, neither consistently faster nor slower) of `long before`.

- [ ] **Step 8: Clean up scratch artifacts**

```bash
rm -f "$OLDPWD/elm-after"
git worktree remove /tmp/elm-kernel-list-padding-before --force
docker volume rm elm-dist-before
rm -rf /tmp/elm-kernel-list-padding-bench
```

No commit for this task — it's verification only, produces no repo changes.
