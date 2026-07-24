#!/usr/bin/env bash
#
# Rebuild this demo with the freshly-built (containerized) elm compiler.
#
# The compiler binary lives inside the `elm-dist` Docker volume, so we run it
# via the same haskell:9.8.4 container that built it.
#
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$DEMO_DIR/.." && pwd)"

docker run --rm \
  -v "$REPO_DIR":/work -w /work \
  -v elm-cabal-home:/root/.cabal \
  -v elm-dist:/work/dist-newstyle \
  -v "$DEMO_DIR":/demo \
  -v elm-home:/root/.elm \
  haskell:9.8.4 bash -c '
    export PATH=/opt/ghc/9.8.4/bin:$PATH
    cabal build elm --ghc-options=-O0 >/dev/null 2>&1
    BIN=$(cabal list-bin elm)
    cd /demo
    "$BIN" make src/Main.elm --output=elm.js
  '

echo
echo "Built: $DEMO_DIR/elm.js"
echo "Serve it:  cd \"$DEMO_DIR\" && python3 -m http.server 8000"
echo "Open three tabs: http://localhost:8000/, .../#settings, .../#reports"
