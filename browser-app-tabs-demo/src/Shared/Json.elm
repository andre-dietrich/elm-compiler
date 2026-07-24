module Shared.Json exposing (encode, decoder, encodeOp, opDecoder, codec)

import Bytes.Decode as BD
import Bytes.Encode as BE
import Crdt.Counter as Counter
import Crdt.Dict as CrdtDict
import Crdt.LWW as LWW
import Crdt.RText as RText
import Crdt.Sync exposing (Codec, WireMsg(..))
import Crdt.Wire as Wire
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Shared exposing (SharedOp(..), SharedState)


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


codec : Codec
codec =
    { encodeWireMsg = encodeWireMsg
    , wireMsgDecoder = wireMsgDecoder
    }


encodeWireMsg : WireMsg -> BE.Encoder
encodeWireMsg msg =
    case msg of
        OpMsg op ->
            BE.sequence [ BE.unsignedInt8 0, Wire.string (Encode.encode 0 (encodeOp op)) ]

        RequestState ->
            BE.unsignedInt8 1

        FullState state ->
            BE.sequence [ BE.unsignedInt8 2, Wire.string (Encode.encode 0 (encode state)) ]


wireMsgDecoder : BD.Decoder WireMsg
wireMsgDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\tag ->
                case tag of
                    0 ->
                        Wire.stringDecoder |> BD.andThen (decodeJsonPayload opDecoder OpMsg)

                    1 ->
                        BD.succeed RequestState

                    2 ->
                        Wire.stringDecoder |> BD.andThen (decodeJsonPayload decoder FullState)

                    _ ->
                        BD.fail
            )


decodeJsonPayload : Decoder a -> (a -> WireMsg) -> String -> BD.Decoder WireMsg
decodeJsonPayload jsonDecoder wrap text =
    case Decode.decodeString jsonDecoder text of
        Ok v ->
            BD.succeed (wrap v)

        Err _ ->
            BD.fail
