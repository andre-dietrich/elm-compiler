module Crdt.LWW exposing
    ( LWW, Op
    , init, value, set, applyOp, merge
    , encode, decoder, encodeOp, opDecoder
    , encodeBytes, bytesDecoder, encodeOpBytes, opBytesDecoder
    )

import Bytes.Decode as BD
import Bytes.Encode as BE
import Crdt.Wire as Wire
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


{-| Last-Write-Wins register. Works for any type `a`, including union
types, since it never inspects the value's shape -- it only ever compares
`(clock, site)` to decide which write wins.
-}
type LWW a
    = LWW { site : String, clock : Int, value : a }


type alias Op a =
    { site : String, clock : Int, value : a }


init : String -> a -> LWW a
init site v =
    LWW { site = site, clock = 0, value = v }


value : LWW a -> a
value (LWW r) =
    r.value


set : a -> LWW a -> ( LWW a, Op a )
set newValue (LWW r) =
    let
        clock =
            r.clock + 1
    in
    ( LWW { r | clock = clock, value = newValue }
    , { site = r.site, clock = clock, value = newValue }
    )


applyOp : Op a -> LWW a -> LWW a
applyOp remote (LWW r) =
    if ( remote.clock, remote.site ) >= ( r.clock, r.site ) then
        LWW { site = remote.site, clock = remote.clock, value = remote.value }

    else
        LWW r


merge : LWW a -> LWW a -> LWW a
merge (LWW a) (LWW b) =
    if ( a.clock, a.site ) >= ( b.clock, b.site ) then
        LWW a

    else
        LWW b


encode : (a -> Encode.Value) -> LWW a -> Encode.Value
encode encodeValue (LWW r) =
    Encode.object
        [ ( "site", Encode.string r.site )
        , ( "clock", Encode.int r.clock )
        , ( "value", encodeValue r.value )
        ]


decoder : Decoder a -> Decoder (LWW a)
decoder valueDecoder =
    Decode.map3 (\site clock v -> LWW { site = site, clock = clock, value = v })
        (Decode.field "site" Decode.string)
        (Decode.field "clock" Decode.int)
        (Decode.field "value" valueDecoder)


encodeOp : (a -> Encode.Value) -> Op a -> Encode.Value
encodeOp encodeValue op =
    Encode.object
        [ ( "site", Encode.string op.site )
        , ( "clock", Encode.int op.clock )
        , ( "value", encodeValue op.value )
        ]


opDecoder : Decoder a -> Decoder (Op a)
opDecoder valueDecoder =
    Decode.map3 (\site clock v -> { site = site, clock = clock, value = v })
        (Decode.field "site" Decode.string)
        (Decode.field "clock" Decode.int)
        (Decode.field "value" valueDecoder)


-- BINARY


encodeBytes : (a -> BE.Encoder) -> LWW a -> BE.Encoder
encodeBytes encodeValue (LWW r) =
    BE.sequence [ Wire.uuid r.site, Wire.varint r.clock, encodeValue r.value ]


bytesDecoder : BD.Decoder a -> BD.Decoder (LWW a)
bytesDecoder valueDecoder =
    BD.map3 (\site clock v -> LWW { site = site, clock = clock, value = v })
        Wire.uuidDecoder
        Wire.varintDecoder
        valueDecoder


encodeOpBytes : (a -> BE.Encoder) -> Op a -> BE.Encoder
encodeOpBytes encodeValue op =
    BE.sequence [ Wire.uuid op.site, Wire.varint op.clock, encodeValue op.value ]


opBytesDecoder : BD.Decoder a -> BD.Decoder (Op a)
opBytesDecoder valueDecoder =
    BD.map3 (\site clock v -> { site = site, clock = clock, value = v })
        Wire.uuidDecoder
        Wire.varintDecoder
        valueDecoder
