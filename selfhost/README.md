# selfhost — the Elm compiler, in Elm

Bootstrapped by the Haskell fork in the repo root (the "oracle").
See docs/superpowers/specs/2026-07-04-self-hosted-elm-compiler-design.md.

- `./scripts/build-oracle.sh` — rebuild `bin/elm` from the Haskell sources (Docker)
- `./scripts/test.sh` — run the elm-test suite
- `./scripts/corpus.sh` — compile & run the corpus projects with the oracle
