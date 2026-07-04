Vendored from https://github.com/andre-dietrich/parser-combinators
at commit c75f424 (package version 7.0.2).

This copy is evolved in place for the self-hosted compiler (structured
errors, committed choice, contexts, indentation). Changes are intended
to flow back upstream as the library's next major version.

## Local evolution (M1, 2026-07)

Breaking changes vs upstream 7.0.2 (intended as upstream v8):

- `InputStream` gained `row`/`col` (1-based, incrementally tracked),
  `indent`, `contexts`. New `advance` helper for primitive authors.
- Errors are `List DeadEnd` (`{ row, col, problem, contextStack }` with
  `Problem = Expecting | ExpectingEnd | Custom`) instead of `List String`.
- `currentLocation` is O(1) and 1-based (was 0-based).
- Committed choice: `or`/`choice`/`many`/… no longer backtrack past
  failures that consumed input; `backtrackable` opts out.
- New: `expecting` (label uncommitted failures; `onerror` is an alias),
  `inContext`, `withIndent`, `indentation`, `deadEndsToString`.
