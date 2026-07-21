# Spike Runbook: Nutzen-Check methodology for JS-codegen optimization candidates

This document is **mechanism-only**: it extracts the exact procedure that every prior spike in
this project (TRMC, unwrapped HOFs, ADT shape padding, kernel list padding, record-update
inlining, list fusion v1/v2, bare-producer-chain fusion, closed-lambda-hoisting,
partial-application-callback, html-tag-arity, list-foldr-fusion) has followed, so that a future
spike for *any* candidate can follow it mechanically without re-deriving the methodology each
time. It contains no candidate-specific content — anywhere a candidate needs to plug in
something (its fixture code, its hand-patch diff, its checksum step function), that is marked
`<CANDIDATE: ...>`.

Every numbered procedure below is meant to be followed in order. Steps 1–4 produce raw
measurements; Step 5 turns those measurements into a verdict and a memory file.

## 1. Scratch setup

1. Create a scratch directory **outside the repo**, under the session scratchpad, never
   committed:

   ```
   <scratchpad>/<candidate-slug>-spike/
   ```

   where `<candidate-slug>` is a short kebab-case name for the candidate (e.g. matching the
   shortlist slug it came from). Everything below lives inside this one directory. At the end of
   the spike, the memory file's "Artefakte" section records this path — the directory itself is
   never `git add`ed.

2. Inside it, write a minimal `elm.json`:

   ```json
   {
       "type": "application",
       "source-directories": ["src"],
       "elm-version": "0.19.2",
       "dependencies": {
           "direct": {
               "elm/core": "1.0.5"
               <CANDIDATE: add whatever other elm/* packages the fixture needs,
                e.g. "elm/html", "elm/virtual-dom", "elm/json" — pin to the versions
                already cached in this machine's ELM_HOME if known, otherwise let
                `elm make` resolve+download on first compile>
           },
           "indirect": {}
       },
       "test-dependencies": { "direct": {}, "indirect": {} }
   }
   ```

   `indirect` deps can be left empty; running `elm make` once will populate them itself (add
   network access if running outside Docker — see Section 2).

3. Write `src/Bench.elm`:

   ```elm
   module Bench exposing (main)

   import Platform

   <CANDIDATE: one or more benchmark functions that exercise exactly the codegen
    shape the candidate targets, e.g. `pipeline2 : Int -> Int`, `buildTree : Int -> Html msg`,
    etc. Prefer a single Elm module, no test framework — this is a throwaway fixture, not
    a package.>

   main : Program () () ()
   main =
       Platform.worker
           { init = \_ -> ( (), Cmd.none )
           , update = \_ model -> ( model, Cmd.none )
           , subscriptions = \_ -> Sub.none
           }
   ```

   Use `Platform.worker` (not `Browser.element`) unless the candidate is specifically about
   `Html`/`VirtualDom` codegen, in which case use `Browser.element` so the real
   `_VirtualDom_diff`/`_VirtualDom_node` kernel machinery is present in the output (see
   html-tag-arity-spike's correction, which switched from `Platform.worker` to `Browser.element`
   for exactly this reason once the first fixture proved too synthetic).

## 2. Hand-patch procedure

The default methodology is **hand-patching generated JS**, not rebuilding the Haskell compiler.
Only fall back to a real compiler rebuild if the candidate's effect cannot be simulated by
editing the emitted JS by hand (e.g. it requires a genuinely different `Opt.*`/decision-tree
shape that the hand-patch can't approximate) — bare-producer-chain-fusion is the project's one
precedent for needing this.

1. Compile the fixture with the fork's current `--optimize` codegen, using the Docker recipe from
   this repo's `CLAUDE.md`:

   ```bash
   docker run --rm -v "$PWD":/work -w /work \
     -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
     -v <scratch-project>:/test -v elm-home:/root/.elm \
     haskell:9.8.4 bash -c 'BIN=$(export PATH=/opt/ghc/9.8.4/bin:$PATH; cabal list-bin elm); cd /test && $BIN make src/Bench.elm --optimize --output=elm.js'
   ```

   where `<scratch-project>` is the `<candidate-slug>-spike/` directory from Section 1. This
   produces `elm.js` inside it — treat this file as the "before" variant, e.g. copy it to
   `bench-before.js`.

2. Copy `bench-before.js` to `bench-after.js` and hand-edit it to simulate the candidate's
   target output shape:

   `<CANDIDATE: the specific textual edit(s) — e.g. one changed literal
    ("var _List_Nil = { $: 0 };" → "var _List_Nil = { $: 0, a: null, b: null };"),
    a rewritten function body simulating a fused/specialized code path, or two
    call-sites changed from A2(...) dispatch to direct .f(...) calls. Keep the
    diff as small and mechanical as possible — the goal is to simulate exactly the
    shape the real compiler change would emit, nothing more.>`

3. If the internal function(s) under test are not reachable from `main` (Prod-mode dead-code
   elimination strips anything `main` doesn't reach, and Elm values are otherwise opaque —
   pattern matching from JS isn't possible), expose them via the scope-injection trick used by
   every spike in this project: insert an assignment like

   ```js
   scope.__bench = $author$project$Bench$someInternalName;
   ```

   directly before the `_Platform_export(...)` call at the bottom of the generated file, in
   *both* `bench-before.js` and `bench-after.js` (same injected name, same position). Then call
   `scope.__bench(...)` (or whatever global/module wrapper exposes `scope` — check the generated
   IIFE header) directly from a driver script, bypassing `Platform.worker`/port overhead entirely.

## 3. Correctness-check procedure

Both variants must be proven to produce **identical** output on the same input before any timing
number is trusted. Two acceptable methods, pick whichever fits the output type:

**Method A — bounded, order-sensitive checksum** (for numeric/list-of-numeric results, or
anything reducible to one). Compute it with a combining step of this shape:

```js
// step(x, acc) folds one element into a running checksum. Must be:
//  - order-sensitive (swapping two elements' processing order must change the result)
//  - bounded (must not grow unboundedly — use a modulus, not raw accumulation)
//  - NOT saturating in either operand's failure mode (see pitfalls below)
function step(x, acc) {
  return (acc * 31 + x) % 1000000007;
}

// Apply once, OUTSIDE the timing loop, to each variant's actual output:
const checksumBefore = xs.reduce((acc, x) => step(x, acc), 0);
const checksumAfter  = xsAfter.reduce((acc, x) => step(x, acc), 0);
if (checksumBefore !== checksumAfter) {
  throw new Error(`checksum mismatch: ${checksumBefore} !== ${checksumAfter}`);
}
```

**Method B — structural equality via `JSON.stringify`** (for non-numeric/structured results —
trees, records, list-of-records, VirtualDom nodes/patches):

```js
const before = JSON.stringify(scope.__benchBefore(fixtureInput));
const after  = JSON.stringify(scope.__benchAfter(fixtureInput));
if (before !== after) {
  throw new Error("structural mismatch between before/after variants");
}
```

Run whichever check applies **once**, outside and before the timing loop (Section 4) — never
inside a hot loop, and never rely on the timing loop itself to also validate correctness.

**Two failure modes to actively avoid** (both cost a full debugging cycle in
list-foldr-fusion-spike — do not repeat them):

1. **Checksum that isn't order-sensitive, or that saturates to a constant.** A `step` function
   whose growth explodes into `Infinity` for the tested input range will produce
   `Infinity | 0 === 0` on *both* sides regardless of whether the underlying computation is
   correct — the checksum trivially "matches" broken output. Verify the checksum step function
   stays within safe-integer range for the largest N you plan to test, and sanity-check it
   against a hand-computed value for a tiny N before trusting it at scale.
2. **Combining a deterministic value with itself an even number of times.** If the checksum is
   computed by XORing (or otherwise self-cancelling-combining) the *same* per-run return value
   across an even number of timing repetitions, the result is always the same constant (often
   `0`) independent of correctness — because `a XOR a == 0` for any `a`, repeated an even number
   of times. This is why the checksum must be computed **once**, from one call to each variant,
   *outside* the timing loop — never accumulated across repetitions inside it.

## 4. Benchmark harness procedure

Timing is always done as **interleaved separate Node.js processes**, never separate runs within
one process (in-process runs share JIT warm-up/deopt state and GC timing across variants, which
biases whichever variant runs second). The harness has three files:

- `bench-before.js` / `bench-after.js` — the two hand-patched variants from Section 2, each
  wrapped to accept a size argument via `process.argv` and print a single JSON line
  `{ "ms": <elapsed>, "checksum": <value> }` to stdout after running its rep loop.
- `bench-runner.js` — the driver, run directly with `node bench-runner.js`.

Template for `bench-runner.js`:

```js
const { execFileSync } = require("child_process");

const SIZES = [1000, 10000, 100000, 1000000]; // <CANDIDATE: pick sizes appropriate to the
                                                 // candidate's expected scaling behavior —
                                                 // include at least one small and one large N>
const RUNS_PER_SIZE = 15;      // interleaved reps kept after warmup
const WARMUP_PAIRS = 1;        // discarded before/after pair, per size, before real reps begin

function runOnce(variant, size, reps) {
  const out = execFileSync("node", [`bench-${variant}.js`, String(size), String(reps)], {
    encoding: "utf8",
  });
  return JSON.parse(out.trim().split("\n").pop()); // { ms, checksum }
}

// --- Rep-count calibration (per size): find a rep count that makes ONE process run
// take roughly 500ms-1s. Short runs (~100-150ms) are the html-tag-arity-spike false-positive
// trap: they don't suppress timer/scheduler noise reliably enough to trust a small (<5%) win.
function calibrateReps(size) {
  let reps = 1;
  while (true) {
    const { ms } = runOnce("before", size, reps);
    if (ms >= 500) return reps;
    if (ms === 0) { reps *= 10; continue; }
    reps = Math.ceil(reps * (750 / ms)); // aim for the middle of the 500ms-1s band
    if (reps <= 0) reps = 1;
    if (ms >= 200) break; // one more doubling is enough once in the right order of magnitude
  }
  return reps;
}

for (const size of SIZES) {
  const reps = calibrateReps(size);
  console.log(`# size=${size} reps=${reps} (calibrated for ~500ms-1s/run)`);

  // Discarded warmup pair — not counted in results.
  for (let w = 0; w < WARMUP_PAIRS; w++) {
    runOnce("before", size, reps);
    runOnce("after", size, reps);
  }

  const beforeTimes = [];
  const afterTimes = [];
  let lastChecksumBefore, lastChecksumAfter;

  for (let r = 0; r < RUNS_PER_SIZE; r++) {
    // Interleaved order: before, after, before, after, ... — never all-before-then-all-after,
    // so that any drift over the measurement window (thermal throttling, background load)
    // affects both variants equally rather than biasing one of them.
    const b = runOnce("before", size, reps);
    const a = runOnce("after", size, reps);
    beforeTimes.push(b.ms);
    afterTimes.push(a.ms);
    lastChecksumBefore = b.checksum;
    lastChecksumAfter = a.checksum;
  }

  if (lastChecksumBefore !== lastChecksumAfter) {
    throw new Error(
      `size=${size}: checksum mismatch before=${lastChecksumBefore} after=${lastChecksumAfter}`
    );
  }

  const avg = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
  const median = (xs) => {
    const s = [...xs].sort((a, b) => a - b);
    return s[Math.floor(s.length / 2)];
  };

  const avgB = avg(beforeTimes), avgA = avg(afterTimes);
  const medB = median(beforeTimes), medA = median(afterTimes);
  console.log(
    `  avg before=${avgB.toFixed(2)}ms after=${avgA.toFixed(2)}ms ` +
    `speedup=${(avgB / avgA).toFixed(2)}x (median speedup=${(medB / medA).toFixed(2)}x) ` +
    `checksum=${lastChecksumBefore} (identical both sides)`
  );
}
```

Rules this template encodes, all of which are load-bearing (each one traces back to a specific
prior spike's finding):

1. **Separate child processes per variant**, spawned via `child_process.execFileSync` (or
   equivalent), not two functions called in the same process.
2. **Interleaved order** (`before, after, before, after, ...`), not blocked (`before×N` then
   `after×N`).
3. **Multiple input sizes**, as an explicit array — a single-size result cannot distinguish a
   candidate that wins uniformly from one that only wins in a specific regime (see Section 5,
   CONDITIONAL verdict).
4. **A discarded warmup pair** before real reps begin, per size.
5. **Rep-count calibration to ~500ms-1s per single process run**, done by a quick calibration
   pass, *before* trusting any measured percentage difference — this is the single most
   important rule in this runbook. html-tag-arity-spike measured a reproducible-looking +2.8% at
   ~120ms/run with 15 reps; re-measuring the *same* fixture at ~780ms/run (2000 reps) collapsed
   the effect to ~0% (-0.28% avg / +0.55% median). Any win under roughly 5% measured at a
   short (~100-150ms) single-process runtime must be re-run at the longer calibrated runtime
   before being written up as real.
6. **Checksum printed and compared on every single run**, not just once at setup — a regression
   introduced partway through a long benchmarking session (e.g. by editing the fixture between
   sizes) is otherwise silently invisible until someone happens to look at the output values.
7. Watch for **GC-noise outliers at very large live-set sizes**: kernel-list-padding-spike saw
   15-40% inconsistent outliers at very large N (large heap, major-GC pauses) that vanished when
   scaled down to a smaller live set. If a size shows wildly inconsistent per-run timings (much
   larger spread than the smaller sizes), suspect GC pause interference before concluding
   anything about the candidate — either shrink that size or note the instability explicitly in
   the memory doc rather than silently discarding it.

## 5. Verdict rule

Apply exactly one of these three verdicts, based on the full table of per-size results from
Section 4:

- **POSITIVE** — consistent win across *all* tested sizes/shapes, of a magnitude that survives
  the rep-count recalibration check (rule 5 above). State the speedup range across sizes/runs in
  the memory doc (e.g. "6.4x-14.0x, growing with N").
- **NEGATIVE** — no consistent win across sizes (mixed sign, or all sizes near 0%/within noise
  band), **or** an apparent small win (<~5%) that does not survive re-measurement at the
  calibrated ~500ms-1s runtime. Explicitly write down that the recalibration was performed and
  what it showed, per the html-tag-arity-spike precedent, even when the final verdict is
  negative for a different reason (e.g. a crash, or a regression at a later pipeline stage as in
  list-foldr-fusion-spike).
- **CONDITIONAL** — a real, reproducible win in some size/shape regime and not in another (e.g.
  "many short lists" vs. "one long list", or "N stages" vs. "N stages plus an intervening
  operation of a different kind"). The memory doc **must** state the regime precisely enough
  that a future reader can tell, from a piece of Elm source, which side of the line it falls on
  — not just "sometimes it wins." Say explicitly what code shape gets the win and what code shape
  does not, and if known, why (mechanism-level explanation, e.g. "hot-path shape change only
  triggers as many times as the list is short/long", "amortizes away over one long
  traversal").

## 6. Memory-doc template

Every spike gets exactly one memory file, written regardless of verdict. Confirmed against
`html-tag-arity-spike.md`, `list-foldr-fusion-spike.md`, `list-fusion-v2-spike.md`, and
`kernel-list-padding-spike.md` — all four use this exact frontmatter shape and this exact set of
body section headers (German-language body, as is this project's convention for memory prose;
code/identifiers stay in English/code font as normal).

```markdown
---
name: <candidate-slug>-spike
description: "Nutzen-Check <POSITIV|NEGATIV|POSITIV ABER KONDITIONAL> (<YYYY-MM-DD>): <one-sentence
  summary of the mechanism and the headline number or reason for the verdict>"
metadata:
  node_type: memory
  type: project
  originSessionId: <this session's id>
---

# Nutzen-Check: <candidate name/short description> — <VERDICT WORD(S)>

**Ausgangspunkt:** <where the candidate idea came from — which shortlist doc, which prior
spike's "future work" note, which research track — and one sentence on the hypothesis /
suspected root cause it targets.>

**Methodik:** <cross-reference to this runbook and/or to the closest prior spike with the same
mechanism, e.g. "Wie [[kernel-list-padding-spike]]/[[list-fusion-v2-spike]]: Scratch-Projekt
(`<slug>-spike/`, Session-Scratchpad, nicht im Repo), Fork-Compiler (main `<commit>`) kompiliert
`Bench.elm` mit <fixture description>. Hand-fusionierte/-gepatchte Vergleichsversion: <one
sentence on the hand-patch>. Korrektheit: <checksum or JSON.stringify method used, plus mention
of any validation bugs found+fixed, if any — see Section 3's two pitfalls>." Interleaved separate
Node-Prozesse, Checksum-Kontrolle bei jedem Lauf, Rep-Kalibrierung auf ~500ms-1s/Prozesslauf.>

**Ergebnis** (<sizes tested>, <N> interleaved Reps nach <M> verworfenem(n) Warmup-Paar(en),
Checksum bei jeder Messung identisch): <table or inline numbers per size — avg/median ms
before/after, resulting speedup or percentage, per size or regime.>

**Schlussfolgerung:** <one paragraph: does this become an implementation-plan candidate for
later, or is it discarded? If CONDITIONAL, restate the regime precisely here too, not just in
the Ergebnis section. If NEGATIVE, name which prior discarded spike(s) this result pattern-
matches (e.g. "wie [[partial-application-callback-spike]]"). If POSITIVE, note what a follow-up
design/implementation plan would need to cover.>

**Artefakte** (Scratch, nicht im Repo):
`<full scratchpad path>/<candidate-slug>-spike/` (elm.json, src/Bench.elm, bench-before.js/
bench-after.js, bench-runner.js<, plus any other files actually produced>).

Build-Rezept: [[build-setup]]. Methodik: [[<closest prior spike(s) with the same or a related
mechanism>]].
```

Notes on filling this in:

- The `description` frontmatter field is the only place the verdict word is guaranteed to be
  read on its own (it is what shows up in a memory index/search) — always bake the verdict and
  date into it, per every existing spike memory file.
- `originSessionId` is this session's id (available via the environment, not invented).
- The `[[double-bracket]]` links are this project's convention for cross-referencing other
  memory files by their `name` field — always link at least the closest-mechanism prior spike
  under both "Methodik" and the closing "Build-Rezept: [[build-setup]]. Methodik: [[...]]" line,
  so future spikes (and this runbook's own maintenance) can be found by following the link graph
  backward from any one memory file.
- The "Artefakte" section's scratch path is descriptive record-keeping only — it is never turned
  into a commit, and the directory is expected to be cleaned up or left orphaned in `/tmp`
  (session-scoped) without further action.
