# Bytes-based wire protocol for `browser-app-tabs-demo`

## Context

`browser-app-tabs-demo/` (a demo project, not the compiler itself — see `CLAUDE.md`) syncs a CRDT
`SharedState` across `Browser.application` tabs via `Crdt.Sync`, which wraps two ports
(`crdtSend`/`crdtReceive`) around a pluggable transport (`crdt-runtime.js`, default `BroadcastChannel`).
The wire format today is `Json.Encode.Value`/`Json.Decode.Value`.

Two rounds of work already attacked payload size for the dominant cost driver, `Crdt.List`'s Fugue tree
(used by `Crdt.RText`, the collaborative text field): Yjs-style tombstone-content GC (negligible effect —
`null` is not smaller than a quoted single-character JSON string) and per-field site-UUID interning
(the real win: ~2.1x smaller, 14775 B → 7054 B for a 70-character document). This spec is the next step:
replace JSON with a hand-rolled binary format via `elm/bytes`, to cut the remaining structural overhead
that JSON's field names, decimal-ASCII integers, and quote/comma punctuation still cost.

Verified against this repo's own compiler source (`compiler/src/Canonicalize/Effects.hs:159-178`) rather
than assumed: port payload types are structurally whitelisted to `Int`/`Float`/`Bool`/`String`/
`Json.Encode.Value`/`List`/`Maybe`/`Array` (plus tuples/records of these). `Bytes.Bytes` is **not** on
that list and cannot cross a port directly — this shapes the port-boundary design below.

## Goals

- A binary wire format that is a straight swap for the JSON one: same `WireMsg` semantics (`OpMsg`,
  `RequestState`, `FullState`), same CRDT correctness, meaningfully smaller on the wire.
- Switchable per build: which codec `Crdt.Sync` uses is one argument at the `Main.elm` call site, not a
  structural rewrite.
- Full protocol coverage (`FullState` *and* every `Op`), so the switch is total, not partial.

## Non-goals

- No change to CRDT semantics, merge rules, or the existing JSON codec's behavior (it stays, unchanged,
  as `Shared.Json`).
- No cross-field (whole-`SharedState`) site-UUID table — see "Site interning" below for why per-field
  tables were chosen instead.
- No change to `crdt-runtime.js`'s backoff/suppression logic (the freeze fix) or `BroadcastChannel`
  transport choice.

## Architecture

### Module layout

- **`Shared.elm`** shrinks to the format-agnostic parts only: `SharedState`, `SharedOp`, `init`,
  `applyOp`, `sync`. Its current `encode`/`decoder`/`encodeOp`/`opDecoder` move out.
- **`Shared/Json.elm`** (new) — today's `encode`/`decoder`/`encodeOp`/`opDecoder`, moved verbatim.
- **`Shared/Binary.elm`** (new) — the binary equivalents, same four function names, operating on
  `Bytes.Encode.Encoder`/`Bytes.Decode.Decoder` instead of `Json.Encode.Value`/`Json.Decode.Decoder`.
- **`Crdt/Counter.elm`, `Crdt/LWW.elm`, `Crdt/Set.elm`, `Crdt/Dict.elm`, `Crdt/List.elm`** each gain a
  second codec section in the *same file*, mirroring the existing `-- JSON` block with a `-- BINARY`
  block (`encodeBytes`/`bytesDecoder`/`encodeOpBytes`/`opBytesDecoder`). Not split into separate files —
  only the `Shared` seam, where the actual codec switch happens, needs two files; splitting all five CRDT
  modules would double the file count for no consumer-visible benefit.
- **`Crdt/Wire.elm`** (new) — low-level primitives every module's binary codec needs, since `elm/bytes`
  doesn't provide them: unsigned LEB128 `varint`/`varintDecoder`, `uuid`/`uuidDecoder` (16 raw bytes ⇄
  canonical 36-char string), length-prefixed `string`/`stringDecoder`, `bool`/`boolDecoder`,
  `list`/`listDecoder`, `maybe`/`maybeDecoder`. Also the port-boundary conversion:
  `toPortString : Bytes -> String` / `fromPortString : String -> Bytes` (see "Port boundary" below).
- **`Crdt/Sync.elm`** — `application` takes a `Codec` record as a new first argument:
  ```elm
  type alias Codec =
      { encodeWireMsg : WireMsg -> Bytes.Encode.Encoder
      , wireMsgDecoder : Bytes.Decode.Decoder WireMsg
      }
  ```
  `WireMsg` itself (`OpMsg SharedOp | RequestState | FullState SharedState`) stays defined once in
  `Crdt.Sync`, format-agnostic; only its byte-level encode/decode is supplied externally.
- **`Main.elm`** picks the codec: `Crdt.Sync.application Shared.Binary.codec { get = ..., set = ... } { ... }`
  (or `Shared.Json.codec` to switch back) — that argument is the entire switch.

### Port boundary

Ports change from `Json.Decode.Value`/`Json.Encode.Value` to `String`:

```elm
port crdtSend : String -> Cmd msg
port crdtReceive : (String -> msg) -> Sub msg
```

The `String` is not JSON text (in the binary codec's case) — it's a **binary string**: one JS UTF-16 code
unit per byte, value 0–255, produced by `Bytes.Decode.loop`-ing over the encoded `Bytes` and building the
string via `Char.fromCode`. This beats the two alternatives considered:

- **Base64** would be ~33% *larger* than the raw bytes — solves a problem (transports that can't carry
  raw byte values) we don't have, since we control both ends of the port.
- **`List Int`** (one `Int` per byte) has no wire-size advantage over a binary string, and costs more to
  cross the port: `String` is a native passthrough in the Elm runtime (the JS string value is handed
  across directly), while `List Int` must be walked cons-cell-by-cons-cell into a JS array and back.

Because every code point stays in 0–255, V8 stores the string internally as one-byte (Latin1), not
two-byte (UTF-16) — so its structured-clone size over `BroadcastChannel` is close to 1 byte per byte, not
inflated the way a full UTF-16 string or base64 text would be.

`crdt-runtime.js` converts at the edges, once each direction:

```js
// before postMessage
const bytes = Uint8Array.from(portString, c => c.charCodeAt(0));
// after receiving from the channel (chunked to avoid the spread-argument stack limit)
function bytesToPortString(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
  }
  return s;
}
```

The `BroadcastChannel` itself now carries a real `Uint8Array`/`ArrayBuffer`, structurally cloned — no
JSON re-serialization on that hop (this matches today's behavior: `crdt-runtime.js` already passes the
JS value straight to `postMessage`; `JSON.stringify` there is only used for the console log).

Console logging (`logMessage`) can no longer assume a readable JSON payload for the binary codec: log
byte length always; for a human-readable preview, only attempt `JSON.parse`/pretty-print when the codec
is `Shared.Json` (still a binary string of ASCII JSON text in that case, trivially convertible back), and
fall back to a short hex dump otherwise.

## Wire format

### Primitives (`Crdt/Wire.elm`)

- **`varint`**: unsigned LEB128 (7 bits per byte, high bit = continuation). Every integer in this
  codebase is non-negative (clocks, tags, node counters, bucket increment/decrement counts, list/string
  lengths) — confirmed by reading each module's mutation code — so no zigzag/signed variant is needed.
- **`uuid`**: 16 raw bytes, parsed from/rendered to the canonical 8-4-4-4-12 hex string
  (`crypto.randomUUID()`'s format). Every site id in this codebase is one of these UUIDs.
- **`string`**: `varint` byte-length prefix + raw UTF-8 bytes (`Bytes.Encode.string`/
  `Bytes.Decode.string`). Covers `LWW`'s value, `Dict String Bool`'s keys, and (via `String.fromChar`)
  `RText`'s individual `Char`s.
- **`bool`**: single byte, 0 or 1.
- **`list encodeElem`**: `varint` count prefix + elements back to back.
- **`maybe encodeElem`**: 1-byte presence flag (0/1), followed by the element if present.

### Site interning: per-field, not global

Each of `Counter`, `Set`, `Dict`, `List` keeps building its **own** small site table in its `FullState`
binary encoding — the same pattern already shipped and proven for `Crdt.List`'s JSON codec (`collectSites`/
`siteIndex`/`siteAt`). Considered and rejected: a single table spanning the whole `SharedState`, which
would dedupe a site UUID that happens to appear in multiple fields. Rejected because it requires threading
a shared index/lookup function through every module's encoder and decoder (breaking each module's
self-containedness), for a saving that's negligible here: this demo has a handful of tab-site UUIDs total,
so repeating one ~16 bytes across up to 4 fields costs at most a few dozen bytes, dwarfed by what the
`RText` tree's node count already costs. Per-field tables keep each module independently
understandable/testable, matching the existing JSON design.

`Op` payloads keep full 16-byte UUIDs, unindexed — same rationale as the existing JSON `encodeOp`: a
single op references at most one or two sites, too few for a table to pay for itself.

### `WireMsg` framing (`Shared/Binary.elm`, used by `Crdt.Sync`'s injected codec)

One leading tag byte:

| Tag | Variant | Body |
|-----|---------|------|
| 0 | `OpMsg` | `SharedOp` |
| 1 | `RequestState` | (none) |
| 2 | `FullState` | `SharedState` |

### `SharedOp` (tag byte selects the field, body is that field's `Op`)

| Tag | Field |
|-----|-------|
| 0 | `TotalOp Counter.Op` |
| 1 | `TagsOp (Dict.Op String Bool)` |
| 2 | `TitleOp (LWW.Op String)` |
| 3 | `NotesOp RText.Op` |

### Per-type `FullState` layouts

**`Counter`**: site table (`list uuid`), then
`{ siteIdx: varint, bucketCount: varint, buckets: bucketCount × { siteIdx: varint, inc: varint, dec: varint } }`
(`siteIdx` fields are `varint` indices into the leading table, same convention as every type below).

**`LWW a`**: `{ site: uuid, clock: varint, value: T }` (`T` = the caller-supplied element encoder, e.g.
`string` for `LWW String`). No table — only one site appears in an `LWW`'s own state (concurrent writers
aren't retained, only the current winner is), so interning has nothing to dedupe.

**`Set comparable` / `Dict comparable v`**: site table (`list uuid`), then
`{ siteIdx: varint, clock: varint, addsCount: varint, adds: addsCount × Tag, removesCount: varint, removes: removesCount × Tag }`
where `Tag = { siteIdx: varint, element: T, tag: varint }` (`Dict` additionally carries
`entriesCount: varint, entries: entriesCount × { key: T, value: T, tag: varint }`).

**`Crdt.List.Sequence a` (`RText`)**: site table (`list uuid`), then
`{ siteIdx: varint, clock: varint, nodeCount: varint, nodes: nodeCount × NodeEntry, rootLeftCount: varint, rootLeft: rootLeftCount × NodeIdIndexed, rootRightCount: varint, rootRight: rootRightCount × NodeIdIndexed }`
where:
- `NodeIdIndexed = { siteIdx: varint, counter: varint }`
- `NodeEntry = { id: NodeIdIndexed, hasValue: bool, value: T if hasValue, hasParent: bool, parent: NodeIdIndexed if hasParent, side: bool (0=L, 1=R), leftChildrenCount: varint, leftChildren: × NodeIdIndexed, rightChildrenCount: varint, rightChildren: × NodeIdIndexed }`

This mirrors the existing JSON-indexed format field-for-field (see `Crdt/List.elm`'s current
`encodeNodeEntryIndexed`/`nodeEntryIndexedDecoder`), just re-expressed in the binary primitives above.

### Per-type `Op` layouts (unindexed, full UUIDs)

- **`Counter.Op`**: tag byte (0=Increment, 1=Decrement) + `{ site: uuid }`.
- **`LWW.Op a`**: `{ site: uuid, clock: varint, value: T }`.
- **`Set.Op comparable` / `Dict.Op comparable v`**: tag byte (0=Add, 1=Remove) + either
  `{ site: uuid, element/key: T, [value: T for Dict], tag: varint }` or `{ tagsCount: varint, tags: × { site: uuid, element/key: T, tag: varint } }`.
- **`Crdt.List.Op a`**: tag byte (0=Insert, 1=Delete) + either
  `{ id: { site: uuid, counter: varint }, value: T, hasParent: bool, parent: { site: uuid, counter: varint } if hasParent, side: bool }`
  or `{ id: { site: uuid, counter: varint } }`.

## Testing / verification

Same manual process the JSON interning work used (no automated test suite in this project — see
`CLAUDE.md`; this demo is a plain `elm make` build via the scratch-project Docker recipe, not the
compiler's own `cabal build`):

1. Build `browser-app-tabs-demo/` with `Shared.Binary` wired into `Main.elm`; must compile cleanly.
2. Round-trip check per CRDT module: encode then decode a hand-built value in each of `Counter`, `LWW`,
   `Set`, `Dict`, `Crdt.List`, both `Op` and `FullState` shapes, assert equality — done ad hoc via a
   scratch `Debug.log`-driven check in `Main.elm` (or `elm repl`), since there's no test runner.
3. Cross-codec correctness: with `Shared.Binary` wired in, repeat the existing manual test plan (Counter
   increment/decrement convergence, OR-Set/Dict add-wins, LWW convergence, Fugue interleaving self-check,
   RText insert/delete) via `chrome-devtools-mcp`, same as prior verification rounds.
4. Size comparison: repeat the exact 70-character RText measurement used for the interning verification
   (type the same string, read the stats panel's "Gesamter Zustand codiert" size) under `Shared.Binary`
   and compare against the already-recorded `Shared.Json` numbers (14775 B pre-interning, 7054 B
   post-interning) to quantify the binary format's additional gain.
5. Confirm switching codecs is really one line: change the `Crdt.Sync.application` argument in
   `Main.elm`, rebuild, re-verify.

## Known limitations

- `Bytes.Decode` failure is all-or-nothing (no partial-message recovery) — same failure mode the JSON
  decoder already has (`Err _ -> ( model, Cmd.none )` in `Crdt.Sync`), not a regression.
- A build running `Shared.Binary` cannot talk to a tab running `Shared.Json` (or a different binary
  layout version) — same cross-build incompatibility already documented for JSON schema changes (see the
  "tombstone resurrection" incidents in prior work); switching codecs requires reloading all open tabs to
  the same build, same as any other wire-format change.
