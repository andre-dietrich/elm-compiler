# Cyclic modules — Plan 2: scheduler wiring — design

Date: 2026-07-08

## Context

[Plan 1](2026-07-07-cyclic-modules-design.md) shipped `Canonicalize.Harvest`
(now on `main`) — given a cyclic SCC of modules' parsed source plus real
interfaces for everything outside the SCC, it resolves the SCC's mutually
recursive `type` (union) declarations and every value's explicit annotation
into one stub `Interface` per module, without needing any member's own full
compile to finish first. Plan 1 deliberately did not touch `Build.hs`: its
scheduler forks one thread per module, and each blocks via `readMVar` on its
dependencies' result `MVar`s (`Build.hs:459-460`) — a real cycle run through
that unchanged deadlocks two threads waiting on each other forever, not just
compiles incorrectly.

Plan 2 is the rest of the feature: make `elm make` actually compile a project
containing an admissible cyclic SCC end-to-end, including correct incremental
rebuilds (the interface-cache atomicity concern Plan 1's design doc flagged
as unaddressed and highest-risk — a cyclic SCC's `.elmi`/`.elmo` files must
invalidate and recompile as one unit, not per-module).

## Architecture

A cyclic SCC becomes **one more forked worker in `Build.hs`'s existing
concurrent scheme**, not a separate phase before or after it. Today,
`forkWithKey (checkModule env foreigns rmvar) statuses` forks one thread per
module, each producing one `MVar Result`. The change: partition `statuses`
into ordinary modules (unchanged — one `checkModule` fork each) and cyclic
SCCs, detected via the same `Graph.stronglyConnComp` `checkForCycles` already
runs (`Build.hs:614-633`), just no longer treated as an unconditional
failure. Each SCC gets **one** new forked worker, `checkCyclicSCC`, covering
all its members at once.

`checkCyclicSCC` blocks (`readMVar`) on the SCC's dependencies *outside*
itself exactly the way `checkModule`/`checkDeps` already do for ordinary
imports — so a cyclic SCC that itself imports other (acyclic) local modules
is handled for free by the existing blocking-`MVar` dependency graph; no
special-casing needed for that case. It never blocks on its own members: those
resolve internally via `Harvest.harvest` (Pass A: stub interfaces for the
whole SCC) followed by `Compile.compile` per member (Pass B). Pass B's
per-member calls can still run concurrently with each other (via the same
`fork` helper used elsewhere), since each only needs Harvest's already-complete
stubs for its SCC peers, never a peer's own Pass-B result. After all of Pass B
succeeds, a whole-SCC `Canonicalize.Module.findCyclicKeys` post-check runs
over the real `Can.Def`s (keyed `(ModuleName.Raw, Name.Name)`, direct-dependency
edges among argument-less defs only — mirroring `toNodeTwo`'s existing
single-module rule) to catch an illegitimate cross-module CAF/value cycle.
Only once *all* of this succeeds does `checkCyclicSCC` fill in each member's
individual, pre-existing `MVar Result` slot — so to every other module reading
`results ! someSCCMember`, a cyclic SCC member looks exactly like any other
module that simply finished a bit later. `checkDeps`/`checkModule` need **no
changes** for this to work; they already just `readMVar` generically.

## Caching — reuses the existing mechanism, no new on-disk format

`Details.Local` (`Elm/Details.hs:98-106`) already carries a `_lastChange`/
`_lastCompile` `BuildID` pair specifically so a module recompiles when a
*dependency* changed even if its own source didn't — the exact mechanism a
cyclic SCC needs. Tracing `checkDeps`/`checkModule`'s existing logic confirms
it already cascades "B changed ⇒ A (which imports B) recompiles too" within a
single run, via the same blocking-`MVar` reads — a real cycle only breaks this
because the blocking deadlocks, not because the staleness logic is wrong.

The joint-staleness rule falls out for free: **if any SCC member's own
crawl-phase status is `SChanged` (or newly added), the whole SCC gets a fresh
Harvest+Compile; if every member is `SCached` and every member's cached
`.elmi` loads without corruption (reusing the existing `Corrupted` handling in
`loadInterface`), reuse them all — exactly like the acyclic `DepsSame` path
does today.** No new persisted fields, no new file format. The one new rule:
if *any* member's cached interface is `Corrupted`, treat the *whole* SCC as
needing a fresh Harvest+Compile, not just that member (today's per-module
`Corrupted` handling only blocks the one affected module).

**Commit ordering:** don't write *any* SCC member's `.elmi`/`.elmo` until
Harvest, all of Pass B, and the `findCyclicKeys` post-check have all
succeeded for the whole SCC — all-or-nothing. This matches, and does not
exceed, the crash-atomicity guarantees the existing per-module cache already
has today (a crash between writing two files is unhandled in both cases); the
new requirement is only that a *successful* run never leaves the SCC's files
mutually inconsistent.

**SCC membership is never persisted.** It's recomputed fresh from the current
import graph on every run. If an import changes such that a module leaves or
joins a cycle between runs, that module's own source changed too (the import
line itself), so it's independently `SChanged` per the ordinary per-module
mtime check — no special-casing needed for membership churn.

## Error handling

New `Reporting.Exit.BuildProjectProblem` cases, added to the two Plan 1
already introduced (`BP_CycleValue`, `BP_CycleMissingAnnotation`):

- `Harvest.Failure`'s `AliasCycle` → new `BP_CycleAlias`, rendered the same
  shape as `BP_CycleValue`.
- `Harvest.Failure`'s `UnsupportedInCycle` (ports/effect managers/custom
  operators — added during Plan 1's review-driven fix rounds, not in Plan 1's
  original scope) → new `BP_CycleUnsupported`. `Reporting.Exit` should not
  depend on `Canonicalize.Harvest`'s internals, so `Exit.hs` gets its own
  small mirror type (three cases matching `Harvest.Restriction`); `Build.hs`'s
  translation layer maps one onto the other.
- `Harvest.Failure`'s `CanonicalizeError` → this is already an ordinary
  per-module `Canonicalize.Error`; it renders through the existing
  `Error.Module`/`RProblem` path unchanged. No new `Exit` case needed.
- A `findCyclicKeys` hit on the whole SCC's real, post-Pass-B `Can.Def`s
  (the value-cycle rejection Plan 1's detector was built for but never
  wired up) → `Exit.BP_CycleValue` (already exists).

## Scope boundary

All three of `Build.hs`'s entry points (`fromExposed`, `fromPaths`,
`fromRepl`) already funnel cycle detection through `checkMidpoint`/
`checkMidpointAndRoots` — rewriting those two is sufficient; no separate
per-entry-point changes needed.

**Inherited from Plan 1, unchanged:** only `type` (union) declarations may be
mutually recursive across an SCC (`type alias` cycles rejected); every value
in a cyclic-SCC module needs an explicit annotation; no ports/effect
managers/custom operators in a cyclic-SCC module; only same-project `src/`
modules participate (a cyclic SCC can *depend on* a published package, never
*cycle with* one).

**Out of scope for Plan 2:**
- `--optimize`/`Mode.Prod` parity is asserted by the original design (codegen
  operates on the whole-program `Opt.GlobalGraph`, module-boundary-agnostic)
  but should be explicitly verified once this compiles real programs, not
  just assumed.
- Performance of the cyclic-SCC path itself (e.g. `Harvest`'s per-lookup
  type-table rebuilding, noted as a non-issue at realistic SCC sizes during
  Plan 1's review) is not a goal here.

## Testing / verification

No automated test suite exists in this repo — verification is manual, per
the existing convention: build in Docker, run the built `elm` against scratch
projects. Required scenarios:

1. **End-to-end compile of an admissible cyclic SCC** — the same shape Plan
   1 unit-verified in isolation (mutually recursive unions, a cross-module
   annotated function), now compiled for real via `elm make` and run under
   Node, confirming both `Mode.Dev` and `Mode.Dev`+`--optimize` output.
2. **Each rejection path end-to-end** — a value cycle, a `type alias` cycle,
   a missing annotation, a port/effect/custom-operator in a cyclic module —
   confirming the right `Exit.BP_Cycle*` error surfaces via `elm make`, not
   just via the `Harvest`-level `Either Failure` this was verified against in
   Plan 1.
3. **Incremental rebuild, no change** — build the SCC once, rebuild with no
   source changes, confirm no recompilation happens (cheap/fast second run,
   observable via timing or a debug trace) and the emitted JS is unchanged.
4. **Incremental rebuild, one member changed** — edit one SCC member's body
   (not signature) and rebuild; confirm the *whole* SCC recompiles, not just
   the touched file, and the output reflects the change correctly.
5. **Cache corruption recovery** — hand-corrupt one member's `.elmi` between
   runs, rebuild, confirm the whole SCC recompiles cleanly rather than
   erroring or silently using stale/mismatched interfaces for the other
   members.
6. **SCC membership churn** — start with a real cycle, remove the import that
   creates it, rebuild; confirm the formerly-cyclic modules now compile via
   the normal acyclic path with correct results (and, ideally, the previously
   unaffected member's cache from before the change is still honored if nothing
   about it needed to change).
7. **A cyclic SCC depending on an ordinary local module and on a published
   package** — confirms the "block on outside deps exactly like `checkModule`
   already does" claim holds for both kinds of outside dependency.
