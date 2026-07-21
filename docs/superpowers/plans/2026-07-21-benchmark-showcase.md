# Benchmark Showcase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `benchmark/`, a static HTML showcase comparing the official Elm 0.19.1 compiler against this fork's patched compiler across 6 curated optimization examples plus a `Worker.run` demo section, each independently start-able in its own iframe.

**Architecture:** One Elm mini-project per example (or per old/new side, where the two sides can't share source), each compiled twice — once by the official `elm` binary, once by `./elm-patched` — into static `dist/old.js` / `dist/new.js`. `benchmark/index.html` lazily sets each iframe's `src` on a per-column "Start" button click, so nothing runs until asked for. Five examples use `elm-explorations/benchmark`'s built-in `Benchmark.Runner` UI for ops/sec numbers; the stack-safety and both Worker examples are small hand-rolled `Browser.element` apps.

**Tech Stack:** Elm 0.19.x (two compiler binaries), `elm-explorations/benchmark` 1.0.2, `andre-dietrich/worker` 1.0.0 (local-only package, not on the public registry), plain HTML/CSS/JS for the shell (no bundler, no JS framework), `python3 -m http.server` for local viewing.

## Global Constraints

- Baseline compiler: official `elm` on `PATH`, reports `0.19.1`. Fork compiler: `./elm-patched` at repo root, reports `0.19.2`.
- `elm.json`'s `"elm-version"` field for an `"application"` project is an **exact match requirement**, not a range — verified directly: an `elm.json` pinned to `0.19.1` makes `elm-patched` refuse with `ELM VERSION MISMATCH`, and vice versa. Every example therefore needs the right `elm-version` in place *before* the matching compiler runs against it (see per-shape build functions in Task 2).
- `elm-stuff/` and `ELM_HOME` (`~/.elm`) caches are namespaced by the compiler's own reported version (`builder/src/Stuff.hs:39`), so official (`0.19.1`) and fork (`0.19.2`) builds never share/corrupt each other's cache even in the same project directory — no special cache isolation needed.
- `andre-dietrich/worker` is **not on the public Elm package registry** — `elm install andre-dietrich/worker` fails with `UNKNOWN PACKAGE`. It only resolves because it's already present in `~/.elm/0.19.2/packages/andre-dietrich/worker/1.0.0/`. Any `elm.json` that uses it must be **hand-authored** (not `elm install`-generated) with `"andre-dietrich/worker": "1.0.0"` added directly under `dependencies.direct`.
- A function passed to `Worker.run` must not belong to a recursive top-level group — **even plain self-recursion trips this** (verified: a directly self-recursive `fib` is rejected with `BAD WORKER CALL ... part of a group of functions that call each other recursively`). The fix, used throughout: define the top-level function as a thin non-recursive wrapper around a `let`-local recursive helper (`fib n = let go k = ... in go n`).
- `Worker.run`'s error type is written as `Result String b` in every example here: the worker-side dispatcher's `catch (e) { self.postMessage({ id, error: String(e) }) }` path (the one that fires for a crash/exception) always produces a plain JS string, which is what actually reaches `Task.attempt`'s `Err` branch at runtime.
- The repo's root `.gitignore` already ignores any `dist` directory — generated `dist/old.js` / `dist/new.js` per example are never committed.
- All page copy (headings, descriptions, button labels, Worker UI text) is **English**, including comments in example `.elm` files meant to be read by a visitor.
- No network calls beyond `elm make`'s own package downloads happen at page-view time — everything is prebuilt static JS, served by a plain static file server.

---

## File Structure

```
benchmark/
  build.sh
  index.html
  .gitignore                                 # ignores examples/*/elm.json (see Task 2)
  shared/
    style.css
    harness.js                               # lazy-iframe-start + crash banner, loaded by every page
  examples/
    list-pipeline-fusion/
      elm.old.json  elm.new.json             # identical except "elm-version"
      src/Main.elm
      frame-old.html  frame-new.html
      dist/                                  # generated
    html-producer-chain-fusion/               (same shape)
    trmc-stack-safety/                        (same shape, no elm-explorations/benchmark)
    kernel-list-shape-padding/                (same shape)
    unwrapped-hofs/                           (same shape)
    record-update-inlining/
      elm.old.json  elm.new.json
      src/MainOld.elm  src/MainNew.elm
      frame-old.html  frame-new.html
      dist/
    worker-fibonacci/
      old/elm.json  old/src/Main.elm
      new/elm.json  new/src/Main.elm
      frame-old.html  frame-new.html
      dist/
    worker-ackermann/                         (same shape as worker-fibonacci)
```

Every example directory has exactly one `frame-old.html` / `frame-new.html` pair, differing only in which compiled script (`dist/old.js` vs `dist/new.js`) they load — this holds even for the five "same Elm source, two compilers" examples.

---

### Task 1: Shared harness (`shared/style.css`, `shared/harness.js`)

**Files:**
- Create: `benchmark/shared/style.css`
- Create: `benchmark/shared/harness.js`
- Test: `benchmark/shared/harness.smoke.html` (temporary manual fixture, deleted at the end of this task)

**Interfaces:**
- Produces: `installStartButtons()` / `installCrashBanner()`, both auto-run on `DOMContentLoaded` — every later page just does `<script src=".../shared/harness.js"></script>` and adds `data-start-for="<iframe id>"` buttons plus a matching `<iframe id="..." data-src="...">`.
- Consumes: nothing from earlier tasks.

- [ ] **Step 1: Write `shared/style.css`**

```css
:root {
  --border: #d8d8d8;
  --bg-old: #fdf6f6;
  --bg-new: #f4fbf6;
  --accent: #2a6f4d;
}

body {
  font-family: -apple-system, "Segoe UI", Roboto, sans-serif;
  max-width: 960px;
  margin: 0 auto;
  padding: 24px 16px 80px;
  color: #222;
  line-height: 1.5;
}

h1 {
  font-size: 1.8rem;
}

section.example {
  border-top: 1px solid var(--border);
  padding-top: 24px;
  margin-top: 32px;
}

section.example h2 {
  margin-bottom: 4px;
}

.teaser {
  color: var(--accent);
  font-weight: 600;
  margin: 4px 0 12px;
}

pre.snippet {
  background: #f6f6f6;
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 12px;
  overflow-x: auto;
  font-size: 0.85rem;
}

.columns {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
  margin-top: 12px;
}

.column {
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 12px;
}

.column.old {
  background: var(--bg-old);
}

.column.new {
  background: var(--bg-new);
}

.column h3 {
  margin-top: 0;
  font-size: 1rem;
}

.column button {
  padding: 6px 14px;
  font-size: 0.9rem;
  cursor: pointer;
}

.column button:disabled {
  opacity: 0.6;
  cursor: default;
}

.column iframe {
  width: 100%;
  height: 260px;
  border: 1px solid var(--border);
  margin-top: 8px;
  background: #fff;
}

#crash-banner {
  position: fixed;
  left: 0;
  right: 0;
  bottom: 0;
  padding: 8px 12px;
  background: #b00020;
  color: #fff;
  font: 13px monospace;
  z-index: 9999;
}

@media (max-width: 680px) {
  .columns {
    grid-template-columns: 1fr;
  }
}
```

- [ ] **Step 2: Write `shared/harness.js`**

```js
(function () {
  "use strict";

  function installStartButtons() {
    document.querySelectorAll("[data-start-for]").forEach(function (button) {
      var iframe = document.getElementById(button.getAttribute("data-start-for"));
      if (!iframe) {
        return;
      }
      button.addEventListener("click", function () {
        if (iframe.getAttribute("src")) {
          return;
        }
        iframe.setAttribute("src", iframe.getAttribute("data-src"));
        button.textContent = "Running…";
        button.disabled = true;
      });
    });
  }

  function installCrashBanner() {
    function show(message) {
      var banner = document.getElementById("crash-banner");
      if (!banner) {
        banner = document.createElement("div");
        banner.id = "crash-banner";
        document.body.appendChild(banner);
      }
      banner.textContent = "💥 " + message;
    }

    window.addEventListener("error", function (event) {
      show(event.message || String(event.error));
    });
    window.addEventListener("unhandledrejection", function (event) {
      show(String(event.reason));
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    installStartButtons();
    installCrashBanner();
  });
})();
```

- [ ] **Step 3: Write a temporary smoke-test fixture**

```html
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8" /><title>harness smoke test</title></head>
<body>
  <button data-start-for="f">▶ Start</button>
  <iframe id="f" data-src="data:text/html,<script>throw new Error('boom')</script>"></iframe>
  <script src="harness.js"></script>
</body>
</html>
```

- [ ] **Step 4: Manually verify**

Run: `cd benchmark/shared && python3 -m http.server 8010`, open `http://localhost:8010/harness.smoke.html`.
Expected: clicking "▶ Start" loads the iframe, the button becomes disabled and reads "Running…", and a red "💥 Error: boom" (or similar) banner appears at the bottom of the page — confirming both `installStartButtons` and `installCrashBanner` work. Stop the server (Ctrl-C).

- [ ] **Step 5: Delete the fixture and commit**

```bash
rm benchmark/shared/harness.smoke.html
git add benchmark/shared/style.css benchmark/shared/harness.js
git commit -m "feat: add shared harness (lazy iframe start, crash banner) for benchmark showcase"
```

---

### Task 2: `build.sh` and the `.gitignore` for generated `elm.json`

**Files:**
- Create: `benchmark/build.sh`
- Create: `benchmark/.gitignore`

**Interfaces:**
- Produces: `build_shared_source <dir>`, `build_split_source <dir>`, `build_split_project <dir>` shell functions, and the list of calls at the bottom that Tasks 3–10 each add one line to.
- Consumes: `./elm-patched` at repo root (already built, per `CLAUDE.md`), official `elm` on `PATH`.

- [ ] **Step 1: Write `benchmark/.gitignore`**

```
examples/*/elm.json
```

(Only matches the generated top-level `elm.json` in the five/six same-directory examples — `examples/worker-*/old/elm.json` and `.../new/elm.json` are one level deeper and are real, committed source of truth, not matched by this pattern.)

- [ ] **Step 2: Write `benchmark/build.sh`**

```bash
#!/usr/bin/env bash
#
# Builds every benchmark example with both the official Elm compiler and
# this fork's patched compiler, producing dist/old.js and dist/new.js per
# example. See docs/superpowers/specs/2026-07-21-benchmark-showcase-design.md
# for why two compiler runs never share a stale cache (they report different
# versions) and why elm.json must be swapped per compiler run (elm-version is
# an exact-match requirement for application projects, not a range).
#
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$BENCH_DIR/.." && pwd)"
ELM_PATCHED="$REPO_DIR/elm-patched"

# Shape A: examples/<name>/src/Main.elm, one source compiled by both compilers.
build_shared_source() {
  local dir="$1"
  mkdir -p "$dir/dist"
  cp "$dir/elm.old.json" "$dir/elm.json"
  (cd "$dir" && elm make src/Main.elm --optimize --output=dist/old.js)
  cp "$dir/elm.new.json" "$dir/elm.json"
  (cd "$dir" && "$ELM_PATCHED" make src/Main.elm --optimize --output=dist/new.js)
}

# Shape B: examples/<name>/src/MainOld.elm + MainNew.elm, different source per side.
build_split_source() {
  local dir="$1"
  mkdir -p "$dir/dist"
  cp "$dir/elm.old.json" "$dir/elm.json"
  (cd "$dir" && elm make src/MainOld.elm --optimize --output=dist/old.js)
  cp "$dir/elm.new.json" "$dir/elm.json"
  (cd "$dir" && "$ELM_PATCHED" make src/MainNew.elm --optimize --output=dist/new.js)
}

# Shape C: examples/<name>/old/ + new/, each a fully self-contained Elm project.
build_split_project() {
  local dir="$1"
  mkdir -p "$dir/dist"
  (cd "$dir/old" && elm make src/Main.elm --optimize --output=../dist/old.js)
  (cd "$dir/new" && "$ELM_PATCHED" make src/Main.elm --optimize --output=../dist/new.js)
}

echo "== list-pipeline-fusion =="
build_shared_source "$BENCH_DIR/examples/list-pipeline-fusion"

echo "== html-producer-chain-fusion =="
build_shared_source "$BENCH_DIR/examples/html-producer-chain-fusion"

echo "== trmc-stack-safety =="
build_shared_source "$BENCH_DIR/examples/trmc-stack-safety"

echo "== kernel-list-shape-padding =="
build_shared_source "$BENCH_DIR/examples/kernel-list-shape-padding"

echo "== unwrapped-hofs =="
build_shared_source "$BENCH_DIR/examples/unwrapped-hofs"

echo "== record-update-inlining =="
build_split_source "$BENCH_DIR/examples/record-update-inlining"

echo "== worker-fibonacci =="
build_split_project "$BENCH_DIR/examples/worker-fibonacci"

echo "== worker-ackermann =="
build_split_project "$BENCH_DIR/examples/worker-ackermann"

echo
echo "All examples built. Serve with:"
echo "  cd \"$BENCH_DIR\" && python3 -m http.server 8000"
```

```bash
chmod +x benchmark/build.sh
```

- [ ] **Step 3: Verify the script is syntactically valid (examples don't exist yet, so a real run is deferred to Task 12)**

Run: `bash -n benchmark/build.sh`
Expected: no output, exit code 0 (pure syntax check).

- [ ] **Step 4: Commit**

```bash
git add benchmark/build.sh benchmark/.gitignore
git commit -m "feat: add benchmark build.sh orchestrating dual-compiler builds"
```

---

### Task 3: Example 1 — List Pipeline Fusion

**Files:**
- Create: `benchmark/examples/list-pipeline-fusion/elm.old.json`
- Create: `benchmark/examples/list-pipeline-fusion/elm.new.json`
- Create: `benchmark/examples/list-pipeline-fusion/src/Main.elm`
- Create: `benchmark/examples/list-pipeline-fusion/frame-old.html`
- Create: `benchmark/examples/list-pipeline-fusion/frame-new.html`

**Interfaces:**
- Consumes: `../../shared/style.css`, `../../shared/harness.js` (Task 1).
- Produces: `dist/old.js` / `dist/new.js` once built (Task 12), referenced by `index.html` (Task 11) as `examples/list-pipeline-fusion/frame-old.html` / `frame-new.html`.

- [ ] **Step 1: Write `elm.old.json`** (verified dependency closure for `elm-explorations/benchmark` 1.0.2 against official Elm — obtained via a real `elm init` + `elm install elm-explorations/benchmark` run, not hand-guessed)

```json
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            "elm/browser": "1.0.2",
            "elm/core": "1.0.5",
            "elm/html": "1.0.1",
            "elm-explorations/benchmark": "1.0.2"
        },
        "indirect": {
            "BrianHicks/elm-trend": "2.1.3",
            "elm/json": "1.1.4",
            "elm/regex": "1.0.0",
            "elm/time": "1.0.0",
            "elm/url": "1.0.0",
            "elm/virtual-dom": "1.0.5",
            "mdgriffith/style-elements": "5.0.2",
            "robinheghan/murmur3": "1.0.0"
        }
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
```

- [ ] **Step 2: Write `elm.new.json`** (identical, only `elm-version` differs)

Copy `elm.old.json` to `elm.new.json` and change `"elm-version": "0.19.1"` to `"elm-version": "0.19.2"`.

- [ ] **Step 3: Write `src/Main.elm`**

```elm
module Main exposing (main)

import Benchmark exposing (Benchmark, benchmark, describe)
import Benchmark.Runner exposing (BenchmarkProgram, program)


testData : List Int
testData =
    List.range 1 200000


isValid : Int -> Bool
isValid n =
    modBy 2 n == 0


transform : Int -> Int
transform n =
    n * 3


isBig : Int -> Bool
isBig n =
    n > 100


pipeline2 : List Int -> Int
pipeline2 xs =
    xs
        |> List.filter isValid
        |> List.foldl (+) 0


pipeline3 : List Int -> Int
pipeline3 xs =
    xs
        |> List.filter isValid
        |> List.map transform
        |> List.foldl (+) 0


pipeline4 : List Int -> Int
pipeline4 xs =
    xs
        |> List.filter isValid
        |> List.map transform
        |> List.filter isBig
        |> List.foldl (+) 0


sumPipeline : List Int -> Int
sumPipeline xs =
    xs
        |> List.filter isValid
        |> List.map transform
        |> List.sum


main : BenchmarkProgram
main =
    program suite


suite : Benchmark
suite =
    describe "List Pipeline Fusion (N = 200,000)"
        [ benchmark "2-stage: filter -> foldl" (\_ -> pipeline2 testData)
        , benchmark "3-stage: filter -> map -> foldl" (\_ -> pipeline3 testData)
        , benchmark "4-stage: filter -> map -> filter -> foldl" (\_ -> pipeline4 testData)
        , benchmark "filter -> map -> sum" (\_ -> sumPipeline testData)
        ]
```

- [ ] **Step 4: Write `frame-old.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>List Pipeline Fusion — Old (Elm 0.19.1)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 5: Write `frame-new.html`** (identical except the title and script src)

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>List Pipeline Fusion — New (this fork)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 6: Verify it compiles with both compilers**

Run:
```bash
cd benchmark/examples/list-pipeline-fusion
cp elm.old.json elm.json && elm make src/Main.elm --optimize --output=/tmp/old.js
cp elm.new.json elm.json && /path/to/repo/elm-patched make src/Main.elm --optimize --output=/tmp/new.js
rm elm.json
```
Expected: both print `Success! Compiled 1 module.`, no errors. (This exact `Main.elm` + `elm.old.json`/`elm.new.json` pair has already been compiled successfully with both compilers during design verification — this step reconfirms it after the files are in their final repo location.)

- [ ] **Step 7: Commit**

```bash
git add benchmark/examples/list-pipeline-fusion
git commit -m "feat: add List Pipeline Fusion benchmark example"
```

---

### Task 4: Example 2 — Html/Producer-Chain Fusion

**Files:**
- Create: `benchmark/examples/html-producer-chain-fusion/elm.old.json`
- Create: `benchmark/examples/html-producer-chain-fusion/elm.new.json`
- Create: `benchmark/examples/html-producer-chain-fusion/src/Main.elm`
- Create: `benchmark/examples/html-producer-chain-fusion/frame-old.html`
- Create: `benchmark/examples/html-producer-chain-fusion/frame-new.html`

**Interfaces:**
- Consumes: same shared harness as Task 3.
- Produces: `dist/old.js` / `dist/new.js` for `index.html`'s second section.

- [ ] **Step 1: Copy `elm.old.json` / `elm.new.json` from Task 3 verbatim** (same dependency closure — this example also uses `elm-explorations/benchmark`)

```bash
cp benchmark/examples/list-pipeline-fusion/elm.old.json benchmark/examples/html-producer-chain-fusion/elm.old.json
cp benchmark/examples/list-pipeline-fusion/elm.new.json benchmark/examples/html-producer-chain-fusion/elm.new.json
```

- [ ] **Step 2: Write `src/Main.elm`**

```elm
module Main exposing (main)

import Benchmark exposing (Benchmark, benchmark, describe)
import Benchmark.Runner exposing (BenchmarkProgram, program)


testData : List Int
testData =
    List.range 1 200000


isValid : Int -> Bool
isValid n =
    modBy 2 n == 0


transform : Int -> Int
transform n =
    n * 3


isBig : Int -> Bool
isBig n =
    n > 100


final : Int -> String
final n =
    "item-" ++ String.fromInt n


chain2 : List Int -> List String
chain2 xs =
    xs
        |> List.filter isValid
        |> List.map final


chain3 : List Int -> List String
chain3 xs =
    xs
        |> List.filter isValid
        |> List.map transform
        |> List.map final


chain4 : List Int -> List String
chain4 xs =
    xs
        |> List.filter isValid
        |> List.map transform
        |> List.filter isBig
        |> List.map final


main : BenchmarkProgram
main =
    program suite


suite : Benchmark
suite =
    describe "Html/Producer-Chain Fusion (N = 200,000, no final fold)"
        [ benchmark "2-stage: filter -> map" (\_ -> chain2 testData)
        , benchmark "3-stage: filter -> map -> map" (\_ -> chain3 testData)
        , benchmark "4-stage: filter -> map -> filter -> map" (\_ -> chain4 testData)
        ]
```

- [ ] **Step 3: Write `frame-old.html`** (same pattern as Task 3, Step 4, only the title changes)

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Html/Producer-Chain Fusion — Old (Elm 0.19.1)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 4: Write `frame-new.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Html/Producer-Chain Fusion — New (this fork)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 5: Verify it compiles with both compilers**

Run: same pattern as Task 3 Step 6, pointed at `html-producer-chain-fusion`.
Expected: both `Success! Compiled 1 module.` (verified during design against this exact source).

- [ ] **Step 6: Commit**

```bash
git add benchmark/examples/html-producer-chain-fusion
git commit -m "feat: add Html/Producer-Chain Fusion benchmark example"
```

---

### Task 5: Example 3 — TRMC Stack-Safety

**Files:**
- Create: `benchmark/examples/trmc-stack-safety/elm.old.json`
- Create: `benchmark/examples/trmc-stack-safety/elm.new.json`
- Create: `benchmark/examples/trmc-stack-safety/src/Main.elm`
- Create: `benchmark/examples/trmc-stack-safety/frame-old.html`
- Create: `benchmark/examples/trmc-stack-safety/frame-new.html`

**Interfaces:**
- Consumes: shared harness (Task 1) — the crash banner is what makes this example's "old" side legible.
- Produces: `dist/old.js` / `dist/new.js` for `index.html`'s third section.

- [ ] **Step 1: Write `elm.old.json`** (plain `elm init` closure — no `elm-explorations/benchmark` needed here, this is a custom `Browser.element` app)

```json
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            "elm/browser": "1.0.2",
            "elm/core": "1.0.5",
            "elm/html": "1.0.1"
        },
        "indirect": {
            "elm/json": "1.1.4",
            "elm/time": "1.0.0",
            "elm/url": "1.0.0",
            "elm/virtual-dom": "1.0.5"
        }
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
```

- [ ] **Step 2: Write `elm.new.json`** (copy of Step 1 with `"elm-version": "0.19.2"`)

- [ ] **Step 3: Write `src/Main.elm`**

This is the exact recursive shape verified during design (naive `n :: buildList (n + 1) end`, N = 1,000,000): compiled with the official compiler and run under Node, it threw `RangeError: Maximum call stack size exceeded`; compiled with `elm-patched` (TRMC), it completed and returned `1000000`. Here it's wrapped in a `Browser.element` UI with a Start button instead of a headless port, so the outcome is visible on the page (and, on the crash side, via the shared crash banner from `harness.js`).

```elm
module Main exposing (main)

import Browser
import Html exposing (Html, button, div, text)
import Html.Events exposing (onClick)


buildList : Int -> Int -> List Int
buildList n end =
    if n > end then
        []

    else
        n :: buildList (n + 1) end


targetN : Int
targetN =
    1000000


type Status
    = NotStarted
    | Done Int


type alias Model =
    { status : Status }


type Msg
    = StartClicked


init : () -> ( Model, Cmd Msg )
init _ =
    ( { status = NotStarted }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg _ =
    case msg of
        StartClicked ->
            ( { status = Done (List.length (buildList 1 targetN)) }, Cmd.none )


view : Model -> Html Msg
view model =
    div []
        [ button [ onClick StartClicked ] [ text "Start" ]
        , div []
            [ text
                (case model.status of
                    NotStarted ->
                        "Not started. Building a " ++ String.fromInt targetN ++ "-element list recursively."

                    Done n ->
                        "Completed without a stack overflow. List length = " ++ String.fromInt n
                )
            ]
        ]


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }
```

- [ ] **Step 4: Write `frame-old.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>TRMC Stack-Safety — Old (Elm 0.19.1)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 5: Write `frame-new.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>TRMC Stack-Safety — New (this fork)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 6: Verify it compiles with both compilers**

Run: same two-compile pattern as Task 3 Step 6.
Expected: both succeed (no `Debug.*` usage here, so `--optimize` needs nothing extra).

- [ ] **Step 7: Manually verify the crash/success behavior once in a real browser**

Run: `cd benchmark/examples/trmc-stack-safety && python3 -m http.server 8011`, open `http://localhost:8011/frame-old.html` and `http://localhost:8011/frame-new.html` in two tabs, click Start in each.
Expected: old tab shows a red crash banner at the bottom (from `harness.js`'s `window.onerror` listener) and the status text never changes from "Not started…"; new tab's status text changes to "Completed without a stack overflow. List length = 1000000" within well under a second. Stop the server.

- [ ] **Step 8: Commit**

```bash
git add benchmark/examples/trmc-stack-safety
git commit -m "feat: add TRMC Stack-Safety benchmark example"
```

---

### Task 6: Example 4 — Kernel List Shape Padding

**Files:**
- Create: `benchmark/examples/kernel-list-shape-padding/elm.old.json`
- Create: `benchmark/examples/kernel-list-shape-padding/elm.new.json`
- Create: `benchmark/examples/kernel-list-shape-padding/src/Main.elm`
- Create: `benchmark/examples/kernel-list-shape-padding/frame-old.html`
- Create: `benchmark/examples/kernel-list-shape-padding/frame-new.html`

**Interfaces:**
- Consumes: shared harness (Task 1).
- Produces: `dist/old.js` / `dist/new.js` for `index.html`'s fourth section.

- [ ] **Step 1: Copy `elm.old.json` / `elm.new.json` from Task 3** (same `elm-explorations/benchmark` closure)

```bash
cp benchmark/examples/list-pipeline-fusion/elm.old.json benchmark/examples/kernel-list-shape-padding/elm.old.json
cp benchmark/examples/list-pipeline-fusion/elm.new.json benchmark/examples/kernel-list-shape-padding/elm.new.json
```

- [ ] **Step 2: Write `src/Main.elm`**

```elm
module Main exposing (main)

import Benchmark exposing (Benchmark, benchmark, describe)
import Benchmark.Runner exposing (BenchmarkProgram, program)


sumShortLists : Int -> Int
sumShortLists reps =
    List.foldl (\_ acc -> acc + List.sum (List.range 1 5)) 0 (List.range 1 reps)


main : BenchmarkProgram
main =
    program suite


suite : Benchmark
suite =
    describe "Kernel List Shape Padding (many short, freshly-built lists)"
        [ benchmark "sum List.range 1 5, 50,000 times" (\_ -> sumShortLists 50000)
        ]
```

If the two sides' numbers land too close together to read (this optimization's effect, ~+8%, is the smallest in the set and elm-benchmark's sampling noise can occasionally swamp it at low rep counts), raise the `50000` rep count — this was chosen as a reasonable single-call latency for elm-benchmark's adaptive sampler, not a value verified against the ~8% figure specifically; recalibrate at implementation time by comparing the two `Benchmark.Runner` numbers directly.

- [ ] **Step 3: Write `frame-old.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Kernel List Shape Padding — Old (Elm 0.19.1)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 4: Write `frame-new.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Kernel List Shape Padding — New (this fork)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 5: Verify it compiles with both compilers**

Run: same two-compile pattern as Task 3 Step 6.
Expected: both succeed (verified during design against this exact source).

- [ ] **Step 6: Commit**

```bash
git add benchmark/examples/kernel-list-shape-padding
git commit -m "feat: add Kernel List Shape Padding benchmark example"
```

---

### Task 7: Example 5 — Unwrapped HOFs

**Files:**
- Create: `benchmark/examples/unwrapped-hofs/elm.old.json`
- Create: `benchmark/examples/unwrapped-hofs/elm.new.json`
- Create: `benchmark/examples/unwrapped-hofs/src/Main.elm`
- Create: `benchmark/examples/unwrapped-hofs/frame-old.html`
- Create: `benchmark/examples/unwrapped-hofs/frame-new.html`

**Interfaces:**
- Consumes: shared harness (Task 1).
- Produces: `dist/old.js` / `dist/new.js` for `index.html`'s fifth section.

- [ ] **Step 1: Copy `elm.old.json` / `elm.new.json` from Task 3**

```bash
cp benchmark/examples/list-pipeline-fusion/elm.old.json benchmark/examples/unwrapped-hofs/elm.old.json
cp benchmark/examples/list-pipeline-fusion/elm.new.json benchmark/examples/unwrapped-hofs/elm.new.json
```

- [ ] **Step 2: Write `src/Main.elm`**

Deliberately a *single*-stage `List.map` / `List.foldr` call each (not a multi-stage pipe chain) — this fork's producer-chain fusion (Examples 1–2) only fires on 2+-stage chains, so a lone call isolates the call-dispatch-bypass optimization on its own instead of also picking up a fusion win. Because of that, expect a real but likely more modest number here than the historical "+27–28%" figure recorded when this optimization was first measured (that measurement predates fusion and used a multi-stage pipeline, which today would also be fusion-eligible and confound the comparison) — the point of this example is isolating this specific optimization class, not reproducing that exact historical number.

```elm
module Main exposing (main)

import Benchmark exposing (Benchmark, benchmark, describe)
import Benchmark.Runner exposing (BenchmarkProgram, program)


testData : List Int
testData =
    List.range 1 200000


mapOnce : List Int -> List Int
mapOnce xs =
    List.map (\n -> n * 2 + 1) xs


foldrSum : List Int -> Int
foldrSum xs =
    List.foldr (\n acc -> n + acc) 0 xs


main : BenchmarkProgram
main =
    program suite


suite : Benchmark
suite =
    describe "Unwrapped Higher-Order Functions (N = 200,000)"
        [ benchmark "single List.map with lambda" (\_ -> mapOnce testData)
        , benchmark "List.foldr with lambda" (\_ -> foldrSum testData)
        ]
```

- [ ] **Step 3: Write `frame-old.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Unwrapped HOFs — Old (Elm 0.19.1)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 4: Write `frame-new.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Unwrapped HOFs — New (this fork)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 5: Verify it compiles with both compilers**

Run: same two-compile pattern as Task 3 Step 6.
Expected: both succeed (verified during design against this exact source).

- [ ] **Step 6: Commit**

```bash
git add benchmark/examples/unwrapped-hofs
git commit -m "feat: add Unwrapped HOFs benchmark example"
```

---

### Task 8: Example 6 — Record-Update Inlining (dotted-path syntax)

**Files:**
- Create: `benchmark/examples/record-update-inlining/elm.old.json`
- Create: `benchmark/examples/record-update-inlining/elm.new.json`
- Create: `benchmark/examples/record-update-inlining/src/MainOld.elm`
- Create: `benchmark/examples/record-update-inlining/src/MainNew.elm`
- Create: `benchmark/examples/record-update-inlining/frame-old.html`
- Create: `benchmark/examples/record-update-inlining/frame-new.html`

**Interfaces:**
- Consumes: shared harness (Task 1). Uses `build_split_source` from Task 2 (different source per side).
- Produces: `dist/old.js` / `dist/new.js` for `index.html`'s sixth section.

- [ ] **Step 1: Copy `elm.old.json` / `elm.new.json` from Task 3** (same `elm-explorations/benchmark` closure)

```bash
cp benchmark/examples/list-pipeline-fusion/elm.old.json benchmark/examples/record-update-inlining/elm.old.json
cp benchmark/examples/list-pipeline-fusion/elm.new.json benchmark/examples/record-update-inlining/elm.new.json
```

- [ ] **Step 2: Write `src/MainNew.elm`** — uses the new dotted-path update syntax (`{ model | account.address.city = "Berlin" }`), which only compiles on this fork.

```elm
module MainNew exposing (main)

import Benchmark exposing (Benchmark, benchmark, describe)
import Benchmark.Runner exposing (BenchmarkProgram, program)


type alias SmallAddress =
    { city : String }


type alias SmallAccount =
    { address : SmallAddress }


type alias SmallModel =
    { account : SmallAccount }


type alias BigAddress =
    { street : String
    , city : String
    , zip : String
    , country : String
    , state : String
    , unit : String
    }


type alias BigAccount =
    { address : BigAddress }


type alias BigModel =
    { account : BigAccount }


smallModel : SmallModel
smallModel =
    { account = { address = { city = "X" } } }


bigModel : BigModel
bigModel =
    { account =
        { address =
            { street = "Main St"
            , city = "X"
            , zip = "00000"
            , country = "DE"
            , state = "BE"
            , unit = "1"
            }
        }
    }


setSmallCity : SmallModel -> SmallModel
setSmallCity model =
    { model | account.address.city = "Berlin" }


setBigCity : BigModel -> BigModel
setBigCity model =
    { model | account.address.city = "Berlin" }


main : BenchmarkProgram
main =
    program suite


suite : Benchmark
suite =
    describe "Record-Update Inlining (dotted-path syntax)"
        [ benchmark "small record (1 field), dotted path" (\_ -> setSmallCity smallModel)
        , benchmark "large record (6 fields), dotted path" (\_ -> setBigCity bigModel)
        ]
```

- [ ] **Step 3: Write `src/MainOld.elm`** — the semantically-equivalent, hand-nested update that official Elm can parse (dotted-path is a hard `PROBLEM IN RECORD` parse error there, verified during design).

```elm
module MainOld exposing (main)

import Benchmark exposing (Benchmark, benchmark, describe)
import Benchmark.Runner exposing (BenchmarkProgram, program)


type alias SmallAddress =
    { city : String }


type alias SmallAccount =
    { address : SmallAddress }


type alias SmallModel =
    { account : SmallAccount }


type alias BigAddress =
    { street : String
    , city : String
    , zip : String
    , country : String
    , state : String
    , unit : String
    }


type alias BigAccount =
    { address : BigAddress }


type alias BigModel =
    { account : BigAccount }


smallModel : SmallModel
smallModel =
    { account = { address = { city = "X" } } }


bigModel : BigModel
bigModel =
    { account =
        { address =
            { street = "Main St"
            , city = "X"
            , zip = "00000"
            , country = "DE"
            , state = "BE"
            , unit = "1"
            }
        }
    }


setSmallCity : SmallModel -> SmallModel
setSmallCity model =
    let
        account =
            model.account

        address =
            account.address
    in
    { model | account = { account | address = { address | city = "Berlin" } } }


setBigCity : BigModel -> BigModel
setBigCity model =
    let
        account =
            model.account

        address =
            account.address
    in
    { model | account = { account | address = { address | city = "Berlin" } } }


main : BenchmarkProgram
main =
    program suite


suite : Benchmark
suite =
    describe "Record-Update, hand-nested (pre-dotted-path equivalent)"
        [ benchmark "small record (1 field), hand-nested" (\_ -> setSmallCity smallModel)
        , benchmark "large record (6 fields), hand-nested" (\_ -> setBigCity bigModel)
        ]
```

- [ ] **Step 4: Write `frame-old.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Record-Update Inlining — Old (Elm 0.19.1)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.MainOld.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 5: Write `frame-new.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Record-Update Inlining — New (this fork)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.MainNew.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 6: Verify it compiles with both compilers**

Run:
```bash
cd benchmark/examples/record-update-inlining
cp elm.old.json elm.json && elm make src/MainOld.elm --optimize --output=/tmp/old.js
cp elm.new.json elm.json && /path/to/repo/elm-patched make src/MainNew.elm --optimize --output=/tmp/new.js
rm elm.json
```
Expected: both `Success! Compiled 1 module.` (this exact pair of files has already been compiled successfully during design verification).

- [ ] **Step 7: Commit**

```bash
git add benchmark/examples/record-update-inlining
git commit -m "feat: add Record-Update Inlining benchmark example"
```

---

### Task 9: Worker Fibonacci (responsiveness demo)

**Files:**
- Create: `benchmark/examples/worker-fibonacci/old/elm.json`
- Create: `benchmark/examples/worker-fibonacci/old/src/Main.elm`
- Create: `benchmark/examples/worker-fibonacci/new/elm.json`
- Create: `benchmark/examples/worker-fibonacci/new/src/Main.elm`
- Create: `benchmark/examples/worker-fibonacci/frame-old.html`
- Create: `benchmark/examples/worker-fibonacci/frame-new.html`

**Interfaces:**
- Consumes: shared harness (Task 1). Uses `build_split_project` from Task 2 (two fully separate Elm projects — the "old" side must not depend on `andre-dietrich/worker` at all, since the official compiler doesn't trust it as a kernel-code author).
- Produces: `dist/old.js` / `dist/new.js` for the Worker section's first subsection in `index.html`.

- [ ] **Step 1: Write `old/elm.json`** (no `andre-dietrich/worker` dependency — plain blocking Elm, needs `elm/time` for the ticking counter)

```json
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": {
            "elm/browser": "1.0.2",
            "elm/core": "1.0.5",
            "elm/html": "1.0.1",
            "elm/time": "1.0.0"
        },
        "indirect": {
            "elm/json": "1.1.4",
            "elm/url": "1.0.0",
            "elm/virtual-dom": "1.0.5"
        }
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
```

- [ ] **Step 2: Write `old/src/Main.elm`** — blocking `fib`, called directly inside `update` (no `Worker`, no `Task`); the ticking counter is driven by the same `Time.every` subscription used on the new side, so its freezing (or not) during the call is the whole point of the comparison.

```elm
module Main exposing (main)

import Browser
import Html exposing (Html, button, div, input, text)
import Html.Attributes exposing (type_, value)
import Html.Events exposing (onClick, onInput)
import Time


fib : Int -> Int
fib n =
    let
        go k =
            if k < 2 then
                k

            else
                go (k - 1) + go (k - 2)
    in
    go n


type alias Model =
    { input : String
    , ticks : Int
    , result : Maybe Int
    }


type Msg
    = InputChanged String
    | StartClicked
    | Tick


init : () -> ( Model, Cmd Msg )
init _ =
    ( { input = "35", ticks = 0, result = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InputChanged s ->
            ( { model | input = s }, Cmd.none )

        StartClicked ->
            case String.toInt model.input of
                Just n ->
                    -- Blocking: the browser's main thread does this whole
                    -- computation before it can process the Tick subscription
                    -- again, so the ticker below visibly freezes.
                    ( { model | result = Just (fib n) }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Tick ->
            ( { model | ticks = model.ticks + 1 }, Cmd.none )


view : Model -> Html Msg
view model =
    div []
        [ input [ type_ "number", value model.input, onInput InputChanged ] []
        , button [ onClick StartClicked ] [ text "Start" ]
        , div [] [ text ("UI ticks while computing: " ++ String.fromInt model.ticks) ]
        , div [] [ text ("result: " ++ Maybe.withDefault "-" (Maybe.map String.fromInt model.result)) ]
        ]


subscriptions : Model -> Sub Msg
subscriptions _ =
    Time.every 100 (\_ -> Tick)


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
```

- [ ] **Step 3: Write `new/elm.json`** — same closure as `old/elm.json`, plus `andre-dietrich/worker` hand-added to `direct` (not `elm install`-able, see Global Constraints). Verified compiling combination during design.

```json
{
    "type": "application",
    "source-directories": [ "src" ],
    "elm-version": "0.19.2",
    "dependencies": {
        "direct": {
            "elm/browser": "1.0.2",
            "elm/core": "1.0.5",
            "elm/html": "1.0.1",
            "elm/time": "1.0.0",
            "andre-dietrich/worker": "1.0.0"
        },
        "indirect": {
            "elm/json": "1.1.4",
            "elm/url": "1.0.0",
            "elm/virtual-dom": "1.0.5"
        }
    },
    "test-dependencies": { "direct": {}, "indirect": {} }
}
```

- [ ] **Step 4: Write `new/src/Main.elm`** — identical UI shape to the old side, but `fib` runs via `Worker.run` and the result arrives through a `Task`.

```elm
module Main exposing (main)

import Browser
import Html exposing (Html, button, div, input, text)
import Html.Attributes exposing (type_, value)
import Html.Events exposing (onClick, onInput)
import Task
import Time
import Worker


fib : Int -> Int
fib n =
    let
        go k =
            if k < 2 then
                k

            else
                go (k - 1) + go (k - 2)
    in
    go n


type alias Model =
    { input : String
    , ticks : Int
    , result : Maybe Int
    }


type Msg
    = InputChanged String
    | StartClicked
    | GotResult (Result String Int)
    | Tick


init : () -> ( Model, Cmd Msg )
init _ =
    ( { input = "35", ticks = 0, result = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InputChanged s ->
            ( { model | input = s }, Cmd.none )

        StartClicked ->
            case String.toInt model.input of
                Just n ->
                    ( model, Task.attempt GotResult (Worker.run fib n) )

                Nothing ->
                    ( model, Cmd.none )

        GotResult (Ok n) ->
            ( { model | result = Just n }, Cmd.none )

        GotResult (Err _) ->
            ( model, Cmd.none )

        Tick ->
            ( { model | ticks = model.ticks + 1 }, Cmd.none )


view : Model -> Html Msg
view model =
    div []
        [ input [ type_ "number", value model.input, onInput InputChanged ] []
        , button [ onClick StartClicked ] [ text "Start" ]
        , div [] [ text ("UI ticks while computing: " ++ String.fromInt model.ticks) ]
        , div [] [ text ("result: " ++ Maybe.withDefault "-" (Maybe.map String.fromInt model.result)) ]
        ]


subscriptions : Model -> Sub Msg
subscriptions _ =
    Time.every 100 (\_ -> Tick)


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
```

- [ ] **Step 5: Write `frame-old.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Worker Fibonacci — Old (Elm 0.19.1, blocking)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 6: Write `frame-new.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Worker Fibonacci — New (this fork, Worker.run)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 7: Verify it compiles with both compilers**

Run:
```bash
cd benchmark/examples/worker-fibonacci
(cd old && elm make src/Main.elm --optimize --output=/tmp/old.js)
(cd new && /path/to/repo/elm-patched make src/Main.elm --optimize --output=/tmp/new.js)
```
Expected: both `Success! Compiled 1 module.`. (The `new/` combination — this exact `elm.json` plus a `let`-wrapped recursive `fib` passed to `Worker.run`, `Result String Int` as the Task's error type — was compiled successfully under `--optimize` during design verification; grepping the output confirmed both `_Worker_run` and `_Worker_register` appear in the generated JS.)

- [ ] **Step 8: Manually verify responsiveness once in a real browser** (needs an actual `Worker` global — this is meaningless in Node)

Run: `cd benchmark/examples/worker-fibonacci && python3 -m http.server 8012`, open `frame-old.html` and `frame-new.html`, enter `38` in each, click Start.
Expected: old tab's "UI ticks…" counter visibly stops advancing for a few seconds while `fib 38` runs, then jumps and shows the result. New tab's counter keeps advancing smoothly throughout, with the result appearing once the worker replies. Stop the server.

- [ ] **Step 9: Commit**

```bash
git add benchmark/examples/worker-fibonacci
git commit -m "feat: add Worker Fibonacci responsiveness demo"
```

---

### Task 10: Worker Ackermann (graceful-failure demo)

**Files:**
- Create: `benchmark/examples/worker-ackermann/old/elm.json`
- Create: `benchmark/examples/worker-ackermann/old/src/Main.elm`
- Create: `benchmark/examples/worker-ackermann/new/elm.json`
- Create: `benchmark/examples/worker-ackermann/new/src/Main.elm`
- Create: `benchmark/examples/worker-ackermann/frame-old.html`
- Create: `benchmark/examples/worker-ackermann/frame-new.html`

**Interfaces:**
- Consumes: shared harness (Task 1, crash banner matters here too — the old side's uncaught `RangeError` needs it to be visible). Uses `build_split_project`.
- Produces: `dist/old.js` / `dist/new.js` for the Worker section's second subsection.

**Note on calibration:** `ackermann(3, n)` was tested directly (headless, via a port, both compilers) during design: `n=11` completes (`16381`) in a few milliseconds; `n=12` through at least `n=16` reliably throw `RangeError: Maximum call stack size exceeded` on **both** compilers — Ackermann's doubly-nested non-tail recursion isn't a shape TRMC rewrites, so unlike the stack-safety example, the crash boundary itself doesn't move between compilers. The point of this example is specifically that the *offloaded* call fails cleanly without freezing the page, not that the new compiler avoids the crash outright. `m = 3` fixed, `n` input clamped to `4`–`14` in the UI (allow a couple of successful runs below the boundary, and reliable crashes above it).

- [ ] **Step 1: Copy `old/elm.json` from Task 9's `old/elm.json` verbatim** (identical dependency needs — `Browser.element` + `elm/time` ticker, no `Worker`)

```bash
mkdir -p benchmark/examples/worker-ackermann/old benchmark/examples/worker-ackermann/new
cp benchmark/examples/worker-fibonacci/old/elm.json benchmark/examples/worker-ackermann/old/elm.json
cp benchmark/examples/worker-fibonacci/new/elm.json benchmark/examples/worker-ackermann/new/elm.json
```

- [ ] **Step 2: Write `old/src/Main.elm`**

```elm
module Main exposing (main)

import Browser
import Html exposing (Html, button, div, input, text)
import Html.Attributes exposing (type_, value)
import Html.Events exposing (onClick, onInput)
import Time


ackermann : Int -> Int
ackermann n =
    let
        go m k =
            if m == 0 then
                k + 1

            else if k == 0 then
                go (m - 1) 1

            else
                go (m - 1) (go m (k - 1))
    in
    go 3 n


type alias Model =
    { input : String
    , ticks : Int
    , result : Maybe Int
    }


type Msg
    = InputChanged String
    | StartClicked
    | Tick


init : () -> ( Model, Cmd Msg )
init _ =
    ( { input = "10", ticks = 0, result = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InputChanged s ->
            ( { model | input = s }, Cmd.none )

        StartClicked ->
            case String.toInt model.input of
                Just n ->
                    -- If this throws (n >= 12 or so), the shared crash banner
                    -- catches it; the app has been fully blocked up to that
                    -- point, so nothing on this page updates until then.
                    ( { model | result = Just (ackermann n) }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        Tick ->
            ( { model | ticks = model.ticks + 1 }, Cmd.none )


view : Model -> Html Msg
view model =
    div []
        [ text "ackermann(3, n) — try n between 4 and 14"
        , div []
            [ input [ type_ "number", value model.input, onInput InputChanged ] []
            , button [ onClick StartClicked ] [ text "Start" ]
            ]
        , div [] [ text ("UI ticks while computing: " ++ String.fromInt model.ticks) ]
        , div [] [ text ("result: " ++ Maybe.withDefault "-" (Maybe.map String.fromInt model.result)) ]
        ]


subscriptions : Model -> Sub Msg
subscriptions _ =
    Time.every 100 (\_ -> Tick)


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
```

- [ ] **Step 3: Write `new/src/Main.elm`**

```elm
module Main exposing (main)

import Browser
import Html exposing (Html, button, div, input, text)
import Html.Attributes exposing (type_, value)
import Html.Events exposing (onClick, onInput)
import Task
import Time
import Worker


ackermann : Int -> Int
ackermann n =
    let
        go m k =
            if m == 0 then
                k + 1

            else if k == 0 then
                go (m - 1) 1

            else
                go (m - 1) (go m (k - 1))
    in
    go 3 n


type alias Model =
    { input : String
    , ticks : Int
    , result : Maybe Int
    , error : Maybe String
    }


type Msg
    = InputChanged String
    | StartClicked
    | GotResult (Result String Int)
    | Tick


init : () -> ( Model, Cmd Msg )
init _ =
    ( { input = "10", ticks = 0, result = Nothing, error = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        InputChanged s ->
            ( { model | input = s }, Cmd.none )

        StartClicked ->
            case String.toInt model.input of
                Just n ->
                    ( { model | result = Nothing, error = Nothing }
                    , Task.attempt GotResult (Worker.run ackermann n)
                    )

                Nothing ->
                    ( model, Cmd.none )

        GotResult (Ok n) ->
            ( { model | result = Just n }, Cmd.none )

        GotResult (Err message) ->
            ( { model | error = Just message }, Cmd.none )

        Tick ->
            ( { model | ticks = model.ticks + 1 }, Cmd.none )


view : Model -> Html Msg
view model =
    div []
        [ text "ackermann(3, n) — try n between 4 and 14"
        , div []
            [ input [ type_ "number", value model.input, onInput InputChanged ] []
            , button [ onClick StartClicked ] [ text "Start" ]
            ]
        , div [] [ text ("UI ticks while computing: " ++ String.fromInt model.ticks) ]
        , div [] [ text ("result: " ++ Maybe.withDefault "-" (Maybe.map String.fromInt model.result)) ]
        , div [] [ text ("worker error (caught, page still alive): " ++ Maybe.withDefault "-" model.error) ]
        ]


subscriptions : Model -> Sub Msg
subscriptions _ =
    Time.every 100 (\_ -> Tick)


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
```

- [ ] **Step 4: Write `frame-old.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Worker Ackermann — Old (Elm 0.19.1, blocking)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/old.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 5: Write `frame-new.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <title>Worker Ackermann — New (this fork, Worker.run)</title>
  <link rel="stylesheet" href="../../shared/style.css" />
</head>
<body>
  <div id="app"></div>
  <script src="../../shared/harness.js"></script>
  <script src="dist/new.js"></script>
  <script>
    Elm.Main.init({ node: document.getElementById("app") });
  </script>
</body>
</html>
```

- [ ] **Step 6: Verify it compiles with both compilers**

Run: same pattern as Task 9 Step 7, pointed at `worker-ackermann`.
Expected: both `Success! Compiled 1 module.`. (The `ackermann`/`go` shape and the `new/elm.json` dependency set are identical in structure to Task 9's already-verified Fibonacci pair, just a different function body.)

- [ ] **Step 7: Manually verify graceful failure once in a real browser**

Run: `cd benchmark/examples/worker-ackermann && python3 -m http.server 8013`, open `frame-old.html` and `frame-new.html`.
Expected: entering `13` and clicking Start on the old tab freezes the ticker, then a red crash banner appears (page is otherwise unresponsive throughout, including the "UI ticks" counter). Entering `13` on the new tab keeps the ticker running the whole time and, once the worker replies, shows `worker error (caught, page still alive): RangeError: Maximum call stack size exceeded` — with no crash banner and no freeze. Entering `10` on either tab succeeds normally (result `8189`, from the design-time calibration). Stop the server.

- [ ] **Step 8: Commit**

```bash
git add benchmark/examples/worker-ackermann
git commit -m "feat: add Worker Ackermann graceful-failure demo"
```

---

### Task 11: `benchmark/index.html`

**Files:**
- Create: `benchmark/index.html`

**Interfaces:**
- Consumes: `shared/style.css`, `shared/harness.js` (Task 1); every example's `frame-old.html` / `frame-new.html` path (Tasks 3–10) as `data-src` values; the `data-start-for="<iframe id>"` / matching `id` convention from Task 1.
- Produces: nothing consumed further — this is the top-level entry point.

- [ ] **Step 1: Write `benchmark/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Elm Compiler Fork — Benchmark Showcase</title>
  <link rel="stylesheet" href="shared/style.css" />
</head>
<body>
  <h1>Elm Compiler Fork — Benchmark Showcase</h1>
  <p>
    Each example below compiles the same (or, where noted, an equivalent)
    small Elm program with the official Elm 0.19.1 compiler on the left and
    with this fork's patched compiler on the right. Nothing runs until you
    click a "Start" button, so it's safe to leave every panel on the page
    without freezing your browser.
  </p>

  <nav>
    <a href="#list-pipeline-fusion">1. List Pipeline Fusion</a> ·
    <a href="#html-producer-chain-fusion">2. Html/Producer-Chain Fusion</a> ·
    <a href="#trmc-stack-safety">3. TRMC Stack-Safety</a> ·
    <a href="#kernel-list-shape-padding">4. Kernel List Shape Padding</a> ·
    <a href="#unwrapped-hofs">5. Unwrapped HOFs</a> ·
    <a href="#record-update-inlining">6. Record-Update Inlining</a> ·
    <a href="#worker-section">Worker.run demos</a>
  </nav>

  <section class="example" id="list-pipeline-fusion">
    <h2>1. List Pipeline Fusion</h2>
    <p>
      A chain of <code>List.filter</code> / <code>List.map</code> stages ending
      in <code>List.foldl</code> or <code>List.sum</code> normally allocates
      one full intermediate list per stage, then throws every one of them
      away except the last. This fork recognizes that shape at compile time
      and fuses the whole pipeline into a single loop that never allocates
      the intermediate lists at all — a technique called deforestation, or
      fusion.
    </p>
    <p class="teaser">Expected: roughly 8&times;&ndash;16&times; faster, growing with pipeline length.</p>
    <pre class="snippet"><code>pipeline4 : List Int -&gt; Int
pipeline4 xs =
    xs
        |&gt; List.filter isValid
        |&gt; List.map transform
        |&gt; List.filter isBig
        |&gt; List.foldl (+) 0</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1)</h3>
        <button data-start-for="list-pipeline-fusion-old">▶ Start</button>
        <iframe id="list-pipeline-fusion-old" data-src="examples/list-pipeline-fusion/frame-old.html" title="List Pipeline Fusion, old compiler"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork)</h3>
        <button data-start-for="list-pipeline-fusion-new">▶ Start</button>
        <iframe id="list-pipeline-fusion-new" data-src="examples/list-pipeline-fusion/frame-new.html" title="List Pipeline Fusion, new compiler"></iframe>
      </div>
    </div>
  </section>

  <section class="example" id="html-producer-chain-fusion">
    <h2>2. Html/Producer-Chain Fusion</h2>
    <p>
      The same fusion idea, but for a chain with no final fold — the shape
      you get from real UI code like
      <code>Html.ul [] (List.map viewItem (List.filter isVisible items))</code>.
      There's no single accumulator to fold into, so the compiler instead
      fuses the chain into one loop that builds only the final list.
    </p>
    <p class="teaser">Expected: roughly 2.75&times;&ndash;8.17&times; faster.</p>
    <pre class="snippet"><code>chain4 : List Int -&gt; List String
chain4 xs =
    xs
        |&gt; List.filter isValid
        |&gt; List.map transform
        |&gt; List.filter isBig
        |&gt; List.map final</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1)</h3>
        <button data-start-for="html-producer-chain-fusion-old">▶ Start</button>
        <iframe id="html-producer-chain-fusion-old" data-src="examples/html-producer-chain-fusion/frame-old.html" title="Html/Producer-Chain Fusion, old compiler"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork)</h3>
        <button data-start-for="html-producer-chain-fusion-new">▶ Start</button>
        <iframe id="html-producer-chain-fusion-new" data-src="examples/html-producer-chain-fusion/frame-new.html" title="Html/Producer-Chain Fusion, new compiler"></iframe>
      </div>
    </div>
  </section>

  <section class="example" id="trmc-stack-safety">
    <h2>3. TRMC Stack-Safety</h2>
    <p>
      Naive recursive list-building (<code>n :: buildList (n + 1) end</code>)
      isn't tail-recursive in the usual sense — the <code>::</code> happens
      <em>after</em> the recursive call returns — so a plain compiler has no
      choice but to grow the JavaScript call stack by one frame per element.
      This fork detects this "tail recursion modulo cons" (TRMC) shape and
      rewrites it into a loop that builds the list without growing the stack
      at all.
    </p>
    <p class="teaser">Building a 1,000,000-element list this way crashes the official compiler's output; this fork's output finishes in well under a second.</p>
    <pre class="snippet"><code>buildList : Int -&gt; Int -&gt; List Int
buildList n end =
    if n &gt; end then
        []
    else
        n :: buildList (n + 1) end</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1)</h3>
        <button data-start-for="trmc-stack-safety-old">▶ Start</button>
        <iframe id="trmc-stack-safety-old" data-src="examples/trmc-stack-safety/frame-old.html" title="TRMC Stack-Safety, old compiler"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork)</h3>
        <button data-start-for="trmc-stack-safety-new">▶ Start</button>
        <iframe id="trmc-stack-safety-new" data-src="examples/trmc-stack-safety/frame-new.html" title="TRMC Stack-Safety, new compiler"></iframe>
      </div>
    </div>
  </section>

  <section class="example" id="kernel-list-shape-padding">
    <h2>4. Kernel List Shape Padding</h2>
    <p>
      Every freshly-built Elm list node has the same two-field shape
      (<code>{ $, a, b }</code>), but a non-empty node and the empty-list
      value <code>[]</code> don't share that shape in the generated
      JavaScript by default, which costs V8 an extra hidden-class check on
      every access. This fork pads <code>[]</code> to match, in
      <code>--optimize</code> builds only. It's a small, allocation-shape-level
      win rather than an algorithmic one.
    </p>
    <p class="teaser">Expected: roughly +8% on workloads dominated by many short, freshly-built lists — this is the smallest win in this showcase, deliberately included to show not every fix is a headline number.</p>
    <pre class="snippet"><code>sumShortLists : Int -&gt; Int
sumShortLists reps =
    List.foldl
        (\_ acc -&gt; acc + List.sum (List.range 1 5))
        0
        (List.range 1 reps)</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1)</h3>
        <button data-start-for="kernel-list-shape-padding-old">▶ Start</button>
        <iframe id="kernel-list-shape-padding-old" data-src="examples/kernel-list-shape-padding/frame-old.html" title="Kernel List Shape Padding, old compiler"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork)</h3>
        <button data-start-for="kernel-list-shape-padding-new">▶ Start</button>
        <iframe id="kernel-list-shape-padding-new" data-src="examples/kernel-list-shape-padding/frame-new.html" title="Kernel List Shape Padding, new compiler"></iframe>
      </div>
    </div>
  </section>

  <section class="example" id="unwrapped-hofs">
    <h2>5. Unwrapped Higher-Order Functions</h2>
    <p>
      Every call through a generic higher-order function like
      <code>List.map</code> or <code>List.foldr</code> normally goes through
      Elm's generic <code>A2</code>/<code>A3</code> arity-dispatch helpers,
      even when the callback's arity is already known statically. This fork
      bypasses that dispatch and calls the callback directly whenever the
      whole-program analysis can prove it's safe.
    </p>
    <p class="teaser">Expected: a real, positive win — likely more modest than historical multi-stage-pipeline measurements (+27&ndash;28%), since a single call like this doesn't also benefit from the fusion optimizations shown above.</p>
    <pre class="snippet"><code>mapOnce : List Int -&gt; List Int
mapOnce xs =
    List.map (\n -&gt; n * 2 + 1) xs</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1)</h3>
        <button data-start-for="unwrapped-hofs-old">▶ Start</button>
        <iframe id="unwrapped-hofs-old" data-src="examples/unwrapped-hofs/frame-old.html" title="Unwrapped HOFs, old compiler"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork)</h3>
        <button data-start-for="unwrapped-hofs-new">▶ Start</button>
        <iframe id="unwrapped-hofs-new" data-src="examples/unwrapped-hofs/frame-new.html" title="Unwrapped HOFs, new compiler"></iframe>
      </div>
    </div>
  </section>

  <section class="example" id="record-update-inlining">
    <h2>6. Record-Update Inlining (new syntax)</h2>
    <p>
      This fork adds dotted-path record updates: <code>{ model |
      account.address.city = "Berlin" }</code> instead of manually
      re-nesting three record updates by hand. The official compiler simply
      can't parse that — it's new surface syntax, not just a runtime
      difference — so the "old" panel below runs the verbose,
      semantically-equivalent code Elm developers had to write before. On top
      of the syntax, this fork's code generator now always compiles a record
      update to a direct object literal in <code>--optimize</code> builds,
      instead of sometimes calling a runtime helper.
    </p>
    <p class="teaser">Expected: roughly +7%&ndash;35%, scaling with how many fields get copied — shown here at two record sizes.</p>
    <pre class="snippet"><code>-- New syntax (this fork only):
setCity model =
    { model | account.address.city = "Berlin" }

-- Old (official Elm), same result by hand:
setCity model =
    let
        account = model.account
        address = account.address
    in
    { model | account = { account | address = { address | city = "Berlin" } } }</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1)</h3>
        <button data-start-for="record-update-inlining-old">▶ Start</button>
        <iframe id="record-update-inlining-old" data-src="examples/record-update-inlining/frame-old.html" title="Record-Update Inlining, old compiler"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork)</h3>
        <button data-start-for="record-update-inlining-new">▶ Start</button>
        <iframe id="record-update-inlining-new" data-src="examples/record-update-inlining/frame-new.html" title="Record-Update Inlining, new compiler"></iframe>
      </div>
    </div>
  </section>

  <section class="example" id="worker-section">
    <h2>Worker.run: Web Worker Offloading</h2>
    <p>
      <code>Worker.run</code> is a new fork-only feature (backed by the
      separate <code>andre-dietrich/worker</code> package) that runs a plain
      top-level function on a dedicated Web Worker and hands back a
      <code>Task</code>. The official compiler doesn't trust that package as
      a source of kernel code at all, so the "old" panels below run the exact
      same computation directly, blocking the main thread — not a
      compile-error showcase, just how it had to be written before.
    </p>

    <h3 id="worker-fibonacci">Fibonacci — does the UI stay responsive?</h3>
    <p>
      A naive, exponential <code>fib n</code> takes a few real seconds around
      n&nbsp;=&nbsp;35&ndash;38. Both panels tick a counter every 100ms while
      running — watch whether it keeps moving.
    </p>
    <pre class="snippet"><code>fib : Int -&gt; Int
fib n =
    let
        go k = if k &lt; 2 then k else go (k - 1) + go (k - 2)
    in
    go n

-- new side only:
Task.attempt GotResult (Worker.run fib n)</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1, blocking)</h3>
        <button data-start-for="worker-fibonacci-old">▶ Start</button>
        <iframe id="worker-fibonacci-old" data-src="examples/worker-fibonacci/frame-old.html" title="Worker Fibonacci, old (blocking)"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork, Worker.run)</h3>
        <button data-start-for="worker-fibonacci-new">▶ Start</button>
        <iframe id="worker-fibonacci-new" data-src="examples/worker-fibonacci/frame-new.html" title="Worker Fibonacci, new (Worker.run)"></iframe>
      </div>
    </div>

    <h3 id="worker-ackermann">Ackermann — does a crash take the whole page down?</h3>
    <p>
      <code>ackermann(3, n)</code>'s doubly-nested recursion isn't a shape
      either compiler can optimize away, so both eventually hit a real
      JavaScript stack overflow around n&nbsp;=&nbsp;12. Try n&nbsp;=&nbsp;10
      first (succeeds on both), then n&nbsp;=&nbsp;13. The point isn't that
      the crash goes away — it's what happens around it.
    </p>
    <pre class="snippet"><code>ackermann : Int -&gt; Int
ackermann n =
    let
        go m k =
            if m == 0 then k + 1
            else if k == 0 then go (m - 1) 1
            else go (m - 1) (go m (k - 1))
    in
    go 3 n</code></pre>
    <div class="columns">
      <div class="column old">
        <h3>Old (Elm 0.19.1, blocking)</h3>
        <button data-start-for="worker-ackermann-old">▶ Start</button>
        <iframe id="worker-ackermann-old" data-src="examples/worker-ackermann/frame-old.html" title="Worker Ackermann, old (blocking)"></iframe>
      </div>
      <div class="column new">
        <h3>New (this fork, Worker.run)</h3>
        <button data-start-for="worker-ackermann-new">▶ Start</button>
        <iframe id="worker-ackermann-new" data-src="examples/worker-ackermann/frame-new.html" title="Worker Ackermann, new (Worker.run)"></iframe>
      </div>
    </div>
  </section>

  <script src="shared/harness.js"></script>
</body>
</html>
```

- [ ] **Step 2: Verify all internal anchors and iframe ids are unique and consistent**

Run:
```bash
grep -o 'id="[^"]*"' benchmark/index.html | sort | uniq -d
```
Expected: no output (no duplicate ids — every `data-start-for` value must match exactly one iframe `id`).

- [ ] **Step 3: Commit**

```bash
git add benchmark/index.html
git commit -m "feat: add benchmark showcase index page"
```

---

### Task 12: Full build and end-to-end manual verification

**Files:**
- Modify: none (this task only runs what Tasks 1–11 already produced)

**Interfaces:**
- Consumes: everything from Tasks 1–11.

- [ ] **Step 1: Run the full build**

```bash
cd benchmark && ./build.sh
```
Expected: eight `== <name> ==` sections, each followed by two `Success! Compiled 1 module.` lines (or equivalent output confirming a working build), ending in "All examples built." with no `-- ... ERROR --`-style blocks anywhere in the output.

- [ ] **Step 2: Confirm every `dist/old.js` / `dist/new.js` exists**

Run:
```bash
find benchmark/examples -name "*.js" -path "*/dist/*" | sort
```
Expected: 16 files — `dist/old.js` and `dist/new.js` under each of the 8 example directories.

- [ ] **Step 3: Serve the whole showcase and click through every example**

Run: `cd benchmark && python3 -m http.server 8000`, open `http://localhost:8000/`.

Expected, per the "Testing / verification plan" section of `docs/superpowers/specs/2026-07-21-benchmark-showcase-design.md`:
- Examples 1, 2, 4, 5, 6: clicking each of the four Start buttons loads a `Benchmark.Runner` UI in its iframe that starts sampling immediately and settles on an ops/sec number after a few seconds; the "New" column's number is visibly higher than "Old"'s in every case.
- Example 3 (TRMC): "Old" Start eventually shows the red crash banner and the status text stays on "Not started…"; "New" Start shows "Completed without a stack overflow. List length = 1000000" quickly.
- Worker Fibonacci: entering 38 and clicking Start — "Old" panel's tick counter stops advancing until the result appears; "New" panel's counter keeps advancing throughout.
- Worker Ackermann: entering 10 succeeds on both panels; entering 13 — "Old" panel freezes then shows the crash banner; "New" panel keeps ticking and shows the inline `worker error` text, no crash banner.
- Clicking Start on one example while another is mid-run doesn't visibly affect it (independent iframes/documents).

Stop the server once done (Ctrl-C).

- [ ] **Step 4: Fix anything that doesn't match, re-run Step 3 for just the affected example, then commit any fixes**

If a step in Step 3 doesn't match (e.g. `Kernel List Shape Padding`'s ~8% win is too close to call given elm-benchmark's sampling noise, or an Ackermann `n` needs adjusting for the actual machine this runs on), edit the relevant example's `src/Main.elm` per the calibration notes left in Tasks 6 and 10, rebuild just that example (`build_shared_source`/`build_split_project` function call, or just re-run `./build.sh` in full — it's idempotent), and re-verify.

```bash
git add -A
git commit -m "fix: calibrate benchmark showcase numbers against a real run"
```
(Only if changes were needed — skip this commit entirely if Step 3 matched expectations as written.)
