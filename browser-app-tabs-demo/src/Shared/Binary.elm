module Shared.Binary exposing (codec)

import Bytes.Decode as BD
import Bytes.Encode as BE
import Crdt.Counter as Counter
import Crdt.Dict as CrdtDict
import Crdt.LWW as LWW
import Crdt.RText as RText
import Crdt.Sync exposing (Codec, WireMsg(..))
import Crdt.Wire as Wire
import Shared exposing (SharedOp(..), SharedState)


codec : Codec
codec =
    { encodeWireMsg = encodeWireMsg
    , wireMsgDecoder = wireMsgDecoder
    }


encodeWireMsg : WireMsg -> BE.Encoder
encodeWireMsg msg =
    case msg of
        OpMsg op ->
            BE.sequence [ BE.unsignedInt8 0, encodeSharedOp op ]

        RequestState ->
            BE.unsignedInt8 1

        FullState state ->
            BE.sequence [ BE.unsignedInt8 2, encodeState state ]


wireMsgDecoder : BD.Decoder WireMsg
wireMsgDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\tag ->
                case tag of
                    0 ->
                        BD.map OpMsg sharedOpDecoder

                    1 ->
                        BD.succeed RequestState

                    2 ->
                        BD.map FullState stateDecoder

                    _ ->
                        BD.fail
            )


encodeState : SharedState -> BE.Encoder
encodeState s =
    BE.sequence
        [ Counter.encodeBytes s.total
        , CrdtDict.encodeBytes Wire.string Wire.bool s.tags
        , LWW.encodeBytes Wire.string s.title
        , RText.encodeBytes s.notes
        ]


stateDecoder : BD.Decoder SharedState
stateDecoder =
    BD.map4 SharedState
        Counter.bytesDecoder
        (CrdtDict.bytesDecoder Wire.stringDecoder Wire.boolDecoder)
        (LWW.bytesDecoder Wire.stringDecoder)
        RText.bytesDecoder


encodeSharedOp : SharedOp -> BE.Encoder
encodeSharedOp op =
    case op of
        TotalOp o ->
            BE.sequence [ BE.unsignedInt8 0, Counter.encodeOpBytes o ]

        TagsOp o ->
            BE.sequence [ BE.unsignedInt8 1, CrdtDict.encodeOpBytes Wire.string Wire.bool o ]

        TitleOp o ->
            BE.sequence [ BE.unsignedInt8 2, LWW.encodeOpBytes Wire.string o ]

        NotesOp o ->
            BE.sequence [ BE.unsignedInt8 3, RText.encodeOpBytes o ]


sharedOpDecoder : BD.Decoder SharedOp
sharedOpDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\tag ->
                case tag of
                    0 ->
                        BD.map TotalOp Counter.opBytesDecoder

                    1 ->
                        BD.map TagsOp (CrdtDict.opBytesDecoder Wire.stringDecoder Wire.boolDecoder)

                    2 ->
                        BD.map TitleOp (LWW.opBytesDecoder Wire.stringDecoder)

                    3 ->
                        BD.map NotesOp RText.opBytesDecoder

                    _ ->
                        BD.fail
            )
