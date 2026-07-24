module Crdt.Wire exposing
    ( varint, varintDecoder
    , uuid, uuidDecoder
    , string, stringDecoder
    , bool, boolDecoder
    , list, listDecoder
    , maybe, maybeDecoder
    , andMap
    , toPortString, fromPortString
    )

{-| Low-level binary primitives shared by every CRDT module's `-- BINARY`
codec section (see the design spec,
`docs/superpowers/specs/2026-07-24-bytes-wire-protocol-design.md`).
Every integer in this codebase's wire data is non-negative (clocks, tags,
node counters, bucket counts, list/string lengths), so `varint` is plain
unsigned LEB128 -- no zigzag/signed variant needed. Every site id is a
`crypto.randomUUID()`-shaped 36-char string, so `uuid` always round-trips
exactly 16 raw bytes.
-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Bytes.Encode as BE
import Char



-- VARINT (unsigned LEB128, 7 bits/byte, high bit = continuation)


varint : Int -> BE.Encoder
varint n =
    BE.sequence (varintBytes (max 0 n))


varintBytes : Int -> List BE.Encoder
varintBytes n =
    let
        low7 =
            Bitwise.and n 0x7F

        rest =
            Bitwise.shiftRightZfBy 7 n
    in
    if rest == 0 then
        [ BE.unsignedInt8 low7 ]

    else
        BE.unsignedInt8 (Bitwise.or low7 0x80) :: varintBytes rest


varintDecoder : BD.Decoder Int
varintDecoder =
    BD.loop ( 0, 0 ) varintStep


varintStep : ( Int, Int ) -> BD.Decoder (BD.Step ( Int, Int ) Int)
varintStep ( shift, acc ) =
    BD.unsignedInt8
        |> BD.map
            (\byte ->
                let
                    acc2 =
                        Bitwise.or acc (Bitwise.shiftLeftBy shift (Bitwise.and byte 0x7F))
                in
                if Bitwise.and byte 0x80 == 0 then
                    BD.Done acc2

                else
                    BD.Loop ( shift + 7, acc2 )
            )



-- UUID (16 raw bytes <-> canonical 8-4-4-4-12 hex string)


uuid : String -> BE.Encoder
uuid s =
    hexPairs (String.filter ((/=) '-') s)
        |> List.map BE.unsignedInt8
        |> BE.sequence


hexPairs : String -> List Int
hexPairs s =
    case String.toList s of
        hi :: lo :: rest ->
            (hexDigit hi * 16 + hexDigit lo) :: hexPairs (String.fromList rest)

        _ ->
            []


hexDigit : Char -> Int
hexDigit c =
    case Char.toLower c of
        '0' -> 0
        '1' -> 1
        '2' -> 2
        '3' -> 3
        '4' -> 4
        '5' -> 5
        '6' -> 6
        '7' -> 7
        '8' -> 8
        '9' -> 9
        'a' -> 10
        'b' -> 11
        'c' -> 12
        'd' -> 13
        'e' -> 14
        'f' -> 15
        _ -> 0


uuidDecoder : BD.Decoder String
uuidDecoder =
    BD.loop ( 16, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                BD.succeed (BD.Done (List.reverse acc))

            else
                BD.unsignedInt8 |> BD.map (\b -> BD.Loop ( remaining - 1, b :: acc ))
        )
        |> BD.map bytesToUuidString


bytesToUuidString : List Int -> String
bytesToUuidString bytes =
    let
        hex =
            bytes |> List.map byteToHex |> String.concat

        groupLens =
            [ 8, 4, 4, 4, 12 ]
    in
    groupHex groupLens hex |> String.join "-"


groupHex : List Int -> String -> List String
groupHex lens hex =
    case lens of
        [] ->
            []

        len :: rest ->
            String.left len hex :: groupHex rest (String.dropLeft len hex)


byteToHex : Int -> String
byteToHex b =
    String.fromChar (hexChar (Bitwise.shiftRightZfBy 4 b)) ++ String.fromChar (hexChar (Bitwise.and b 0x0F))


hexChar : Int -> Char
hexChar n =
    if n < 10 then
        Char.fromCode (Char.toCode '0' + n)

    else
        Char.fromCode (Char.toCode 'a' + (n - 10))



-- STRING (varint byte-length prefix + raw UTF-8 bytes)


string : String -> BE.Encoder
string s =
    BE.sequence [ varint (BE.getStringWidth s), BE.string s ]


stringDecoder : BD.Decoder String
stringDecoder =
    varintDecoder |> BD.andThen BD.string



-- BOOL (single byte, 0 or 1)


bool : Bool -> BE.Encoder
bool b =
    BE.unsignedInt8
        (if b then
            1

         else
            0
        )


boolDecoder : BD.Decoder Bool
boolDecoder =
    BD.unsignedInt8 |> BD.map (\b -> b /= 0)



-- LIST (varint count prefix + elements back to back)


list : (a -> BE.Encoder) -> List a -> BE.Encoder
list encodeElem xs =
    BE.sequence (varint (List.length xs) :: List.map encodeElem xs)


listDecoder : BD.Decoder a -> BD.Decoder (List a)
listDecoder elemDecoder =
    varintDecoder
        |> BD.andThen
            (\n ->
                BD.loop ( n, [] )
                    (\( remaining, acc ) ->
                        if remaining <= 0 then
                            BD.succeed (BD.Done (List.reverse acc))

                        else
                            elemDecoder |> BD.map (\x -> BD.Loop ( remaining - 1, x :: acc ))
                    )
            )



-- MAYBE (1-byte presence flag, then the element if present)


maybe : (a -> BE.Encoder) -> Maybe a -> BE.Encoder
maybe encodeElem m =
    case m of
        Nothing ->
            BE.unsignedInt8 0

        Just x ->
            BE.sequence [ BE.unsignedInt8 1, encodeElem x ]


maybeDecoder : BD.Decoder a -> BD.Decoder (Maybe a)
maybeDecoder elemDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\flag ->
                if flag == 0 then
                    BD.succeed Nothing

                else
                    BD.map Just elemDecoder
            )



{-| Applicative helper so a record/tuple decoder with more fields than
`Bytes.Decode`'s `map5` ceiling can still be built flat:
`BD.map ctor d1 |> andMap d2 |> andMap d3 |> ...`.
-}
andMap : BD.Decoder a -> BD.Decoder (a -> b) -> BD.Decoder b
andMap =
    BD.map2 (|>)



-- PORT BOUNDARY
--
-- The port carries a plain `String`, one JS UTF-16 code unit per byte
-- (value 0-255) -- not JSON text, not base64. See the design spec's "Port
-- boundary" section for why (native String passthrough at the port,
-- V8 stores an all-Latin1 string as one byte/char).


toPortString : Bytes -> String
toPortString bytes =
    BD.decode (portStringDecoder (Bytes.width bytes)) bytes
        |> Maybe.withDefault ""


portStringDecoder : Int -> BD.Decoder String
portStringDecoder width =
    BD.loop ( width, [] )
        (\( remaining, acc ) ->
            if remaining <= 0 then
                BD.succeed (BD.Done (List.reverse acc))

            else
                BD.unsignedInt8 |> BD.map (\byte -> BD.Loop ( remaining - 1, Char.fromCode byte :: acc ))
        )
        |> BD.map String.fromList


fromPortString : String -> Bytes
fromPortString str =
    str
        |> String.toList
        |> List.map (Char.toCode >> BE.unsignedInt8)
        |> BE.sequence
        |> BE.encode
