# Cyclic module imports (types + functions only) — design

Date: 2026-07-07

## Context

Elm hard-rejects any import cycle between modules: `Build.hs`'s
`checkForCycles` (`Build.hs:614-633`) runs `Data.Graph.stronglyConnComp`
over the crawled module graph and turns any `CyclicSCC` into a
`BP_Cycle` build failure before a single module is compiled. This is
long-standing upstream behavior (confirmed via `git log --author` that no
fork commit has ever touched this code), not something introduced here.

This design allows a *restricted* class of module cycles instead of
rejecting all of them, without weakening any guarantee Elm currently
makes. It follows directly from a guarantee Elm **already** enforces
within a single module: `Canonicalize/Module.hs`'s `toNodeTwo` /
`detectBadCycles` (`Canonicalize/Module.hs:186-201`) allows a group of
mutually recursive **functions** (defs with ≥1 argument — invocation is
deferred, so calling a not-yet-"finished" peer is safe) but rejects a
direct cycle among argument-less **values** (CAFs), since those are
evaluated eagerly at binding time and a direct cycle among them is
non-terminating or reads an uninitialized value. This design generalizes
that exact rule across a module boundary instead of only within one file.

**Correction (found while writing the implementation plan, 2026-07-07):**
this is only true for `type` (union) declarations, not `type alias`.
`Canonicalize/Environment/Local.hs:120-145` shows Elm already rejects
recursive type *aliases* even within a single module
(`Graph.CyclicSCC ... -> Result.throw (Error.RecursiveAlias ...)`) — an
alias is substituted inline, so a cycle is an infinite type expansion,
unlike a `union`, whose constructors are an implicit indirection/box. So:
mutually recursive `type` declarations across modules are fine (same
reasoning as within one module today); mutually recursive `type alias`
declarations across modules must stay rejected, exactly as they already
are within one module, just extended to span the module boundary.

A second correction from the same pass: the two-pass compile below can't
simply be spliced into `Build.hs`'s existing per-module scheduling
unchanged. That scheduler forks one thread per module and each blocks via
`readMVar` on its dependencies' result MVars (`Build.hs:459-460`) — two
modules in a real cycle, run through that path unmodified, deadlock
forever instead of failing cleanly. Members of an admissible cyclic SCC
must be pulled out of that per-module fork/block scheme and compiled by a
dedicated, non-concurrent two-pass routine (the SCC as a whole can still
run concurrently with unrelated modules — just not internally). This is
significant enough that it's split into its own follow-up plan; see
`docs/superpowers/plans/2026-07-07-cyclic-modules-*.md`.

A key finding that shapes the design: **codegen needs no changes**. Once
past `Compile.compile`, everything funnels into one whole-program
`Opt.GlobalGraph` (`AST/Optimized.hs:151-181`) keyed by `Global`
(module + name) — module boundaries don't exist at that level. Mutually
recursive definitions are already represented as a single `Cycle` node
with a `Set.Set Global` dependency set, regardless of which source module
each member came from. The entire problem is confined to the front half
of the pipeline: `Build.hs` scheduling and `Compile.compile`'s assumption
that a module's full `Map.Map ModuleName.Raw Interface` is known and
finished before that module can be compiled (`Compile.hs:39`).

## Scope

**Allowed**, once this ships:
- Mutually recursive `type` (union) declarations across modules.
- Mutually recursive functions across modules — but only when every
  cross-module reference to such a function has an explicit top-level
  type annotation in its defining module (see Pass A below; this is a new
  hard requirement, not just a style nudge).

**Still rejected**, exactly as today:
- Mutually recursive `type alias` declarations across modules — same
  reasoning, and the same error character, as today's intra-module
  `RecursiveAlias`, just naming the modules involved.
- Any direct cross-module cycle among argument-less values (CAFs) — same
  character of error as today's intra-module `RecursiveDecl`, just naming
  the modules involved.
- A cross-module function used cyclically with no explicit annotation —
  new error, see below.

**Out of scope for v1:**
- `--optimize`/`Mode.Prod`-specific concerns: none are expected (see
  codegen finding above), but this is not yet verified end-to-end and
  should be a first-class part of the verification pass, not assumed.
- Any attempt to support real cross-module CAF/value cycles via laziness
  or thunking. Rejected during brainstorming: Elm's JS codegen is eager,
  and reintroducing this would reintroduce exactly the non-termination
  risk the current restriction prevents. Not part of this design at all.
- Cycles spanning package boundaries (a project module cyclically
  depending on a published package). Only same-project `src/` modules are
  in scope; package interfaces are immutable published artifacts and
  can't participate in a harvest/stub pass.

## Architecture

`Build.hs`'s `checkForCycles` gate stops being an unconditional failure.
A detected `CyclicSCC` is routed to a new two-pass compile path instead of
immediately producing `BP_Cycle`; `BP_Cycle` is now only produced if that
SCC later fails the admissibility check below.

**Pass A — harvest a stub `Interface` per module in the SCC:**
1. *Register:* collect every type/alias/union declaration's name+arity
   from every module in the SCC, with no bodies resolved yet — mirroring
   how a single module's `Canonicalize.Environment.Local` already
   registers all local type names before resolving any of their bodies,
   which is precisely what lets one file's types reference each other
   today.
2. *Resolve:* resolve each type/alias/union's real definition using an
   env that includes every SCC peer's just-registered names, permitting
   mutual type recursion across the module boundary the same way it's
   already permitted within one file.
3. *Signatures:* for every exposed value in the SCC that carries an
   explicit top-level type annotation, resolve that annotation (only,
   not the body) into a `Can.Annotation`, using the now-complete
   cross-module type environment from step 2. This reuses the same
   `Canonicalize.Type.toAnnotation` path `toNodeOne` already calls for
   annotated definitions today (`Canonicalize/Module.hs:165-166`).
4. Assemble one stub `Elm.Interface` per SCC module from steps 2-3
   (`_unions`/`_aliases` populated for real, `_values` populated only for
   explicitly annotated exposed names, `_binops` as today).

**Pass B — real compile:** run `Compile.compile` per SCC module exactly
as today, except a fellow SCC member's `Interface` argument is Pass A's
stub instead of a fully-compiled interface. Every other (non-cyclic)
dependency works exactly as it does today.

**Post-check — cycle admissibility:** after Pass B produces a real
`Can.Module` for every SCC member, generalize `toNodeTwo` /
`detectBadCycles`'s direct-dependency analysis (today scoped to one
module's `freeLocals`) across the whole SCC: build one graph over every
definition in every SCC module, edge = "directly uses" (`directUses > 0`,
same as today) restricted to argument-less defs, and reject if any
`CyclicSCC` remains in *that* graph. This is the exact same rule as
today's intra-module check, just fed a bigger graph. If the whole-SCC
check is clean, the two-pass compile is accepted; if not, produce
`BP_Cycle`-equivalent naming the offending modules and value names.

## Interface cache implications

Today `Build.hs` treats each module's `.elmi`/`.elmo` staleness
independently — a module recompiles only if its own source or a direct
dependency's real interface changed. A cyclic SCC breaks that
independence: if module A's source changes in a way that changes its
Pass-A stub (e.g. an edited type signature), module B's Pass-B compile is
invalid even though B's own source didn't change, because B was compiled
against A's *old* stub.

The SCC must therefore be cached and invalidated as **one atomic unit**:
if any member's source changed, or Pass A's harvested output for any
member changed, the entire SCC recompiles, not just the changed file.
This is the highest-risk part of the whole design for a silent
correctness bug (a stale peer compiled against an outdated stub, with no
visible error) and needs the most scrutiny during implementation and
explicit test coverage during verification — see below.

## Error handling

Two new error cases, both rendered through the existing
`Reporting.Error`/`Reporting.Report` machinery used for
`RecursiveDecl`/`BP_Cycle` today:
1. A value used across a cycle boundary with no explicit top-level type
   annotation — message should name the value, the module, and explain
   *why* it's required here specifically (unlike ordinary top-level
   values, which never require an annotation).
2. A genuine cross-module CAF cycle survives the Pass-B post-check — same
   shape as today's `RecursiveDecl`, extended to name the module for each
   value in the cycle (today's version only ever needs one module's
   name).

## Testing / verification

No automated suite exists in this repo (per `CLAUDE.md`) — verification
is manual scratch-project testing, following the existing protocol (build
in Docker, run against a disposable scratch project, inspect output/run
under Node). Required scenarios:

1. **Legal type-only cycle** — `A.Expr` referencing `B.Stmt` and vice
   versa, no cross-module function calls. Should compile as it does for
   an equivalent single-module mutually-recursive type today.
2. **Legal function cycle** — mutually recursive functions across two
   modules, both explicitly annotated. Compiles; compiled JS behavior
   verified under Node (e.g. a cross-module even/odd pair).
3. **Illegal value cycle** — two modules with a direct CAF cycle
   (`A.x = B.y + 1`, `B.y = A.x - 1`). Must be rejected with the new
   cross-module `RecursiveDecl`-equivalent error, not silently miscompiled
   and not crashing the build.
4. **Missing annotation across a cycle** — a legal-shape function cycle
   where one function lacks an explicit top-level annotation. Must
   produce the new "annotation required" error, not an obscure internal
   failure.
5. **Incremental rebuild correctness** (highest risk area) — build the
   legal function-cycle scenario once, then edit only one module's
   signature and rebuild: confirm the *peer* module recompiles too, not
   just the touched file. Then edit only a function *body* (not its
   signature) in one module and rebuild: confirm the peer is correctly
   left alone (an over-aggressive "always recompile the whole SCC on any
   change" would be safe but defeats incremental compilation — worth
   checking which behavior the implementation actually produces and
   deciding if the more precise version is worth the added complexity).
6. **`--optimize` parity** — repeat scenario 2 with `--optimize` and
   confirm both correct output and no crash in the whole-program
   `Opt.GlobalGraph` merge/DCE pass, since this is asserted by design
   above but not yet exercised.
