#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec npx --yes elm-test@0.19.1-revision12 --compiler "$PWD/bin/elm" "$@"
