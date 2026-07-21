# Optimization Research Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Research online for new JS-codegen optimization candidates for the Elm compiler fork, then spike and benchmark every plausible candidate, documenting each in memory — without touching the Haskell compiler itself in this pass.

**Architecture:** Two research tracks (V8 internals, other FP→JS compiler codegen) feed a filtered/ranked shortlist. Each shortlisted candidate goes through the project's established spike procedure (scratch hand-patched JS, checksum-validated correctness, interleaved cross-process benchmarking) via a shared runbook. Results are written to memory per candidate, then aggregated into a summary.

**Tech Stack:** WebSearch/WebFetch for research; Node.js for benchmark harnesses; the project's Docker-based GHC toolchain only if a candidate needs real compiler output instead of hand-patched JS (see `CLAUDE.md` build section).

## Global Constraints

- No changes to `compiler/`, `builder/`, or any other Haskell source in this pass (spec: Explicitly out of scope).
- No cap on the number of candidates spiked (spec: Phase 2).
- Every candidate gets a memory entry regardless of outcome — positive, negative, or conditional (spec: Phase 3).
- Spike methodology per candidate: scratch project outside the repo (session scratchpad, not committed), hand-patched before/after JS variants, correctness verified by checksum or structural comparison, timing via interleaved runs across **separate Node processes**, multiple input sizes, reps calibrated so a single process run takes ~500ms-1s (not 100-150ms — that produced a false positive in `html-tag-arity-spike`).
- Deprioritize candidates in the "bypass dispatch overhead on a monomorphic call site" class — three prior spikes (closed-lambda-hoisting, partial-application-callback, html-tag-arity) found V8 already optimizes these away, near 0% real gain.
- Domain adaptation note: this plan has no unit tests in the conventional sense. Wherever the task-writing template below says "write the failing test" / "run tests", the equivalent in this domain is "write the checksum/structural-equality check between the before/after variant" / "run it and confirm it fails to distinguish correct vs. buggy output, then confirm both variants match."

---

### Task 1: V8 internals research

**Files:**
- Create: `docs/superpowers/specs/2026-07-21-optimization-candidates-v8.md`

**Interfaces:**
- Produces: a markdown file with one section per candidate idea, each containing: idea name, source (URL + one-line what it says), rationale for why it could beat what the fork already does, and which `Generate.JavaScript`/`Generate.Mode` area it would touch.

- [ ] **Step 1: Research current V8 optimization behavior**

Use WebSearch/WebFetch to cover: hidden classes / shape transitions, inline caches (monomorphic vs. polymorphic vs. megamorphic), TurboFan inlining budget/limits, escape analysis and allocation elision, GC behavior under high allocation churn (scavenger/major GC pause triggers), and any V8 team blog posts on optimizing generated/transpiled code specifically (not hand-written JS).

- [ ] **Step 2: Cross-reference against the fork's existing codegen**

For each technique found, check whether the fork already exploits it (grep `compiler/src/Generate/JavaScript` and `compiler/src/Generate/Mode.hs` for related patterns) or whether a prior spike already tested it (search `/home/andre/.claude/projects/-home-andre-Workspace-Projects-Freinet-elm-compiler/memory/*.md` for related terms). Drop anything already covered.

- [ ] **Step 3: Write candidate list to file**

Write `docs/superpowers/specs/2026-07-21-optimization-candidates-v8.md` with one `## Candidate: <name>` section per surviving idea, each with `**Source:**`, `**Rationale:**`, `**Touch points:**`, `**Risk of being a V8-already-handles-this dead end:**` (low/medium/high, one sentence why).

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-21-optimization-candidates-v8.md
git commit -m "docs: V8-internals research notes for optimization sweep"
```

---

### Task 2: Other FP→JS compiler research

**Files:**
- Create: `docs/superpowers/specs/2026-07-21-optimization-candidates-compilers.md`

**Interfaces:**
- Produces: same file structure as Task 1's output, for compiler-codegen-sourced ideas.

- [ ] **Step 1: Research codegen strategies in comparable compilers**

Use WebSearch/WebFetch to cover PureScript, ReScript/BuckleScript, Gleam, Roc, and Fable: how each compiles pattern matching (decision trees vs. something else), currying/arity (curried closures vs. uncurried + arity metadata), record/tuple representation, and tail-call handling (trampolines, loop rewriting, or none).

- [ ] **Step 2: Identify structural deltas from the fork's current approach**

For each technique, note whether it's structurally different from what `Optimize.DecisionTree`/`Optimize.Case`, `Generate.Mode.Arities`, or the Opt-level TRMC/fusion machinery already do. A technique that's just a renamed version of something the fork already has is not a new candidate.

- [ ] **Step 3: Write candidate list to file**

Same format as Task 1 Step 3, in `docs/superpowers/specs/2026-07-21-optimization-candidates-compilers.md`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-21-optimization-candidates-compilers.md
git commit -m "docs: FP-to-JS-compiler research notes for optimization sweep"
```

---

### Task 3: Merge, filter, and rank the shortlist

**Files:**
- Create: `docs/superpowers/specs/2026-07-21-optimization-candidates-shortlist.md`
- Read: both files produced by Task 1 and Task 2

**Interfaces:**
- Consumes: the two candidate-list files from Task 1 and Task 2.
- Produces: `docs/superpowers/specs/2026-07-21-optimization-candidates-shortlist.md`, a single ordered list — this is the authoritative input for Task 5's spike loop. Each entry has a stable slug (kebab-case, used as the memory-file basename in Task 5).

- [ ] **Step 1: Merge both candidate lists**

Concatenate both files' candidates into one working list, deduplicating anything that turned up in both tracks.

- [ ] **Step 2: Apply the filter criterion**

Drop or demote any candidate whose mechanism is "bypass dispatch overhead on a monomorphic call site" (per Global Constraints) unless it has a specific argument for why it differs from the three already-discarded cases (e.g., a genuinely polymorphic/megamorphic call site, or a case involving real allocation savings alongside the dispatch change).

- [ ] **Step 3: Rank by expected payoff mechanism**

Order candidates with "eliminates allocation/traversal" or "changes algorithmic shape" mechanisms first (matching the fork's historically successful pattern — list fusion, shape padding, record update inlining, TRMC), "dead end risk: low" before "medium" before "high".

- [ ] **Step 4: Write the shortlist file**

For each surviving candidate: `## <n>. <slug>: <name>`, one-line hypothesis, expected win mechanism, dead-end risk, and a pointer back to its source file/section from Task 1 or 2.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-07-21-optimization-candidates-shortlist.md
git commit -m "docs: rank and filter optimization candidate shortlist"
```

---

### Task 4: Write the shared spike runbook

**Files:**
- Create: `docs/superpowers/specs/2026-07-21-spike-runbook.md`

**Interfaces:**
- Produces: the procedure Task 5 follows verbatim for every candidate. No candidate-specific content — this file is mechanism-only.

- [ ] **Step 1: Write the scratch-project setup steps**

Document: create `<scratchpad>/<candidate-slug>-spike/` with a minimal `elm.json` (`"elm-version": "0.19.2"`, whatever `elm/*` packages the candidate needs) and `src/Bench.elm`; note this directory is never committed to the repo.

- [ ] **Step 2: Write the hand-patch procedure**

Document: compile `Bench.elm` with the current fork (`--optimize`) to get the "before" JS; hand-edit a copy to produce the "after" JS simulating the candidate optimization's output shape (per `CLAUDE.md`'s Docker build recipe for producing the baseline compiler output).

- [ ] **Step 3: Write the correctness-check procedure**

Document: both variants must produce identical output on the same input — verify via a checksum (a bounded, order-sensitive combining function, per the lesson in `list-foldr-fusion-spike` about avoiding checksums that trivially match on broken output) or `JSON.stringify` structural comparison, computed once outside the timing loop.

- [ ] **Step 4: Write the benchmark harness procedure**

Document: a `bench-runner.js` that spawns the before/after variants as **separate Node child processes**, interleaved, across multiple input sizes, discarding a warmup pair, calibrating rep count per process so a single process run takes ~500ms-1s (per Global Constraints / html-tag-arity-spike lesson), and printing per-run timings plus the checksum.

- [ ] **Step 5: Write the verdict and memory-doc template**

Document the decision rule: POSITIVE (consistent win across sizes), NEGATIVE (no consistent win, or win doesn't survive rep recalibration), CONDITIONAL (wins in some regime, not others — state the regime). Include the exact memory-file frontmatter format used by existing spikes (`name`, `description` with verdict baked in, `metadata: {node_type: memory, type: project}`), and the required content sections: Ausgangspunkt/origin, Methodik, Ergebnis, Schlussfolgerung, Artefakte (scratch path, not committed).

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-07-21-spike-runbook.md
git commit -m "docs: shared spike runbook for optimization research sweep"
```

---

### Task 5: Spike loop — apply the runbook to every shortlisted candidate

**Files:**
- Read: `docs/superpowers/specs/2026-07-21-optimization-candidates-shortlist.md` (Task 3), `docs/superpowers/specs/2026-07-21-spike-runbook.md` (Task 4)
- Create (per candidate, slug from the shortlist): memory file `<candidate-slug>-spike.md` in the auto-memory directory; scratch artifacts under the session scratchpad (not committed)
- Modify: `MEMORY.md` (auto-memory index)

**Interfaces:**
- Consumes: the shortlist from Task 3 (ordered candidate slugs) and the runbook from Task 4 (exact procedure).
- Produces: one memory file per candidate with a verdict, plus one new line per candidate in `MEMORY.md`.

- [ ] **Step 1: Take the next candidate from the shortlist**

Work through `optimization-candidates-shortlist.md` top to bottom. This step repeats once per candidate until the list is exhausted — each iteration is independent and may be parallelized across subagents (candidates don't share scratch state).

- [ ] **Step 2: Run the runbook's setup + hand-patch + correctness-check steps**

Follow `spike-runbook.md` Steps 1-3 for this candidate's specific optimization idea.

- [ ] **Step 3: Run the runbook's benchmark harness**

Follow `spike-runbook.md` Step 4. Confirm the checksum matches on every run before trusting the timing numbers.

- [ ] **Step 4: Determine verdict and write the memory file**

Follow `spike-runbook.md` Step 5. Write `<candidate-slug>-spike.md` to the memory directory (`/home/andre/.claude/projects/-home-andre-Workspace-Projects-Freinet-elm-compiler/memory/`) regardless of verdict.

- [ ] **Step 5: Add the candidate to MEMORY.md**

Append one line: `- [<Title>](<candidate-slug>-spike.md) — <one-line verdict summary>`.

- [ ] **Step 6: Repeat from Step 1 until the shortlist is exhausted**

No commit here — memory files live outside the git repo. If the candidate's spike incidentally produced any repo-tracked file (it shouldn't per the runbook), stop and reconcile before continuing.

---

### Task 6: Aggregate summary and follow-up recommendation

**Files:**
- Create: `docs/superpowers/specs/2026-07-21-optimization-sweep-summary.md`
- Read: every `<candidate-slug>-spike.md` memory file written in Task 5

**Interfaces:**
- Consumes: all Task 5 memory files.
- Produces: `docs/superpowers/specs/2026-07-21-optimization-sweep-summary.md`, the final deliverable of this plan.

- [ ] **Step 1: List every candidate spiked with its verdict**

One line per candidate: slug, verdict (positive/negative/conditional), headline number (e.g., "2.3x at N=10000, ~0% at N=100").

- [ ] **Step 2: Recommend follow-up**

For any POSITIVE or CONDITIONAL verdict, state explicitly that it is a candidate for a future design+implementation-plan cycle (out of scope for this plan per Global Constraints) and name which one(s), if any, look strongest. For an all-NEGATIVE outcome, say so plainly — that is still a valid, useful result.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-21-optimization-sweep-summary.md
git commit -m "docs: summarize optimization research sweep results"
```
