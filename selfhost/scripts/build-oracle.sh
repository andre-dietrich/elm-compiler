#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p selfhost/bin
docker run --rm -v "$PWD":/work -w /work \
  -v elm-cabal-home:/root/.cabal -v elm-dist:/work/dist-newstyle \
  haskell:9.8.4 bash -c 'export PATH=/opt/ghc/9.8.4/bin:$PATH; \
    cabal build elm --ghc-options=-O0 2>&1 | tail -n 20 && \
    cp "$(cabal list-bin elm)" /work/selfhost/bin/elm && \
    chown '"$(id -u):$(id -g)"' /work/selfhost/bin/elm'
./selfhost/bin/elm --version
