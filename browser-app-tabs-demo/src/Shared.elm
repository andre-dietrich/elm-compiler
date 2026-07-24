module Shared exposing
    ( SharedState, SharedOp(..)
    , init
    , encode, decoder, sync
    , encodeOp, opDecoder, applyOp
    )

import Crdt.Counter as Counter
import Crdt.Dict as CrdtDict
import Crdt.LWW as LWW
import Crdt.RText as RText
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


{-| The state shared across tabs. Plain Elm record whose fields happen to
be CRDT types -- no special record-level abstraction needed, this is
composed the same way any Elm app composes a `Json.Decode.mapN` decoder by
hand.
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


encode : SharedState -> Encode.Value
encode s =
    Encode.object
        [ ( "total", Counter.encode s.total )
        , ( "tags", CrdtDict.encode Encode.string Encode.bool s.tags )
        , ( "title", LWW.encode Encode.string s.title )
        , ( "notes", RText.encode s.notes )
        ]


decoder : Decoder SharedState
decoder =
    Decode.map4 SharedState
        (Decode.field "total" Counter.decoder)
        (Decode.field "tags" (CrdtDict.decoder Decode.string Decode.bool))
        (Decode.field "title" (LWW.decoder Decode.string))
        (Decode.field "notes" RText.decoder)


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


encodeOp : SharedOp -> Encode.Value
encodeOp op =
    case op of
        TotalOp o ->
            Encode.object [ ( "kind", Encode.string "total" ), ( "op", Counter.encodeOp o ) ]

        TagsOp o ->
            Encode.object [ ( "kind", Encode.string "tags" ), ( "op", CrdtDict.encodeOp Encode.string Encode.bool o ) ]

        TitleOp o ->
            Encode.object [ ( "kind", Encode.string "title" ), ( "op", LWW.encodeOp Encode.string o ) ]

        NotesOp o ->
            Encode.object [ ( "kind", Encode.string "notes" ), ( "op", RText.encodeOp o ) ]


opDecoder : Decoder SharedOp
opDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "total" ->
                        Decode.map TotalOp (Decode.field "op" Counter.opDecoder)

                    "tags" ->
                        Decode.map TagsOp (Decode.field "op" (CrdtDict.opDecoder Decode.string Decode.bool))

                    "title" ->
                        Decode.map TitleOp (Decode.field "op" (LWW.opDecoder Decode.string))

                    "notes" ->
                        Decode.map NotesOp (Decode.field "op" RText.opDecoder)

                    _ ->
                        Decode.fail ("unknown SharedOp kind: " ++ kind)
            )
