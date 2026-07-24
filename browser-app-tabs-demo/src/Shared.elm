module Shared exposing
    ( SharedState, SharedOp(..)
    , init
    , sync
    , applyOp
    )

import Crdt.Counter as Counter
import Crdt.Dict as CrdtDict
import Crdt.LWW as LWW
import Crdt.RText as RText


{-| The state shared across tabs. Plain Elm record whose fields happen to
be CRDT types -- no special record-level abstraction needed. Encoding
(JSON or binary) lives in `Shared.Json`/`Shared.Binary`, not here.
-}
type alias SharedState =
    { total : Counter.Counter
    , tags : CrdtDict.Dict String Bool
    , title : LWW.LWW String
    , notes : RText.RText
    }


init : String -> SharedState
init site =
    { total = Counter.init site
    , tags = CrdtDict.init site
    , title = LWW.init site ""
    , notes = RText.init site
    }


{-| Only used for the one-time bootstrap exchange when a tab joins --
ongoing changes travel as `SharedOp`, not full-state syncs.
-}
sync : SharedState -> SharedState -> SharedState
sync local remote =
    { total = Counter.merge local.total remote.total
    , tags = CrdtDict.sync local.tags remote.tags
    , title = LWW.merge local.title remote.title
    , notes = RText.sync local.notes remote.notes
    }


type SharedOp
    = TotalOp Counter.Op
    | TagsOp (CrdtDict.Op String Bool)
    | TitleOp (LWW.Op String)
    | NotesOp RText.Op


applyOp : SharedOp -> SharedState -> SharedState
applyOp op s =
    case op of
        TotalOp o ->
            { s | total = Counter.applyOp o s.total }

        TagsOp o ->
            { s | tags = CrdtDict.applyOp o s.tags }

        TitleOp o ->
            { s | title = LWW.applyOp o s.title }

        NotesOp o ->
            { s | notes = RText.applyOp o s.notes }
