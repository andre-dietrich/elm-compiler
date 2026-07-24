module Crdt.Counter exposing
    ( Counter, Op(..)
    , init, value, siteCount, increment, decrement, applyOp, merge
    , encode, decoder, encodeOp, opDecoder
    , encodeBytes, bytesDecoder, encodeOpBytes, opBytesDecoder
    )

import Bytes.Decode as BD
import Bytes.Encode as BE
import Crdt.Wire as Wire
import Dict exposing (Dict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Set


{-| PN-Counter: every site accumulates its own (increments, decrements)
bucket, so concurrent updates from different sites never overwrite each
other. `value` sums (inc - dec) across all sites.
-}
type Counter
    = Counter { site : String, buckets : Dict String ( Int, Int ) }


type Op
    = Increment { site : String }
    | Decrement { site : String }


init : String -> Counter
init site =
    Counter { site = site, buckets = Dict.empty }


increment : Counter -> ( Counter, Op )
increment (Counter c) =
    ( Counter { c | buckets = Dict.update c.site (bump 1 0) c.buckets }
    , Increment { site = c.site }
    )


decrement : Counter -> ( Counter, Op )
decrement (Counter c) =
    ( Counter { c | buckets = Dict.update c.site (bump 0 1) c.buckets }
    , Decrement { site = c.site }
    )


applyOp : Op -> Counter -> Counter
applyOp op (Counter c) =
    case op of
        Increment { site } ->
            Counter { c | buckets = Dict.update site (bump 1 0) c.buckets }

        Decrement { site } ->
            Counter { c | buckets = Dict.update site (bump 0 1) c.buckets }


bump : Int -> Int -> Maybe ( Int, Int ) -> Maybe ( Int, Int )
bump incBy decBy existing =
    case existing of
        Just ( inc, dec ) ->
            Just ( inc + incBy, dec + decBy )

        Nothing ->
            Just ( incBy, decBy )


value : Counter -> Int
value (Counter c) =
    Dict.values c.buckets |> List.foldl (\( inc, dec ) acc -> acc + inc - dec) 0


{-| Number of distinct sites that have ever touched this counter -- the
counter's actual storage cost, since it doesn't grow with the number of
increments, only with the number of participants.
-}
siteCount : Counter -> Int
siteCount (Counter c) =
    Dict.size c.buckets


merge : Counter -> Counter -> Counter
merge (Counter a) (Counter b) =
    Counter
        { site = a.site
        , buckets =
            Dict.merge
                Dict.insert
                (\site va vb acc ->
                    Dict.insert site
                        ( max (Tuple.first va) (Tuple.first vb)
                        , max (Tuple.second va) (Tuple.second vb)
                        )
                        acc
                )
                Dict.insert
                a.buckets
                b.buckets
                Dict.empty
        }


encode : Counter -> Encode.Value
encode (Counter c) =
    Encode.object
        [ ( "site", Encode.string c.site )
        , ( "buckets", Encode.dict identity encodePair c.buckets )
        ]


decoder : Decoder Counter
decoder =
    Decode.map2 (\site buckets -> Counter { site = site, buckets = buckets })
        (Decode.field "site" Decode.string)
        (Decode.field "buckets" (Decode.dict pairDecoder))


encodeOp : Op -> Encode.Value
encodeOp op =
    case op of
        Increment { site } ->
            Encode.object [ ( "kind", Encode.string "increment" ), ( "site", Encode.string site ) ]

        Decrement { site } ->
            Encode.object [ ( "kind", Encode.string "decrement" ), ( "site", Encode.string site ) ]


opDecoder : Decoder Op
opDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "increment" ->
                        Decode.map (\site -> Increment { site = site }) (Decode.field "site" Decode.string)

                    "decrement" ->
                        Decode.map (\site -> Decrement { site = site }) (Decode.field "site" Decode.string)

                    _ ->
                        Decode.fail ("unknown Counter.Op kind: " ++ kind)
            )


encodePair : ( Int, Int ) -> Encode.Value
encodePair ( inc, dec ) =
    Encode.list Encode.int [ inc, dec ]


pairDecoder : Decoder ( Int, Int )
pairDecoder =
    Decode.list Decode.int
        |> Decode.andThen
            (\xs ->
                case xs of
                    [ inc, dec ] ->
                        Decode.succeed ( inc, dec )

                    _ ->
                        Decode.fail "expected [inc, dec]"
            )


-- BINARY
--
-- Site table (`list uuid`) interning every distinct site referenced by
-- this counter (its own site plus every bucket key), then
-- `{ siteIdx, bucketCount, buckets: bucketCount x { siteIdx, inc, dec } }`.
-- `Crdt.Counter`'s JSON codec never interned sites -- this table is new
-- with the binary codec, mirroring the pattern `Crdt.List` already uses.


encodeBytes : Counter -> BE.Encoder
encodeBytes (Counter c) =
    let
        sites =
            collectSites c

        bucketList =
            Dict.toList c.buckets
    in
    BE.sequence
        [ Wire.list Wire.uuid sites
        , Wire.varint (siteIndex sites c.site)
        , Wire.list (encodeBucketBytes sites) bucketList
        ]


encodeBucketBytes : List String -> ( String, ( Int, Int ) ) -> BE.Encoder
encodeBucketBytes sites ( site, ( inc, dec ) ) =
    BE.sequence [ Wire.varint (siteIndex sites site), Wire.varint inc, Wire.varint dec ]


bytesDecoder : BD.Decoder Counter
bytesDecoder =
    Wire.listDecoder Wire.uuidDecoder
        |> BD.andThen
            (\sites ->
                BD.map2
                    (\siteIdx buckets -> Counter { site = siteAt siteIdx sites, buckets = Dict.fromList buckets })
                    Wire.varintDecoder
                    (Wire.listDecoder (bucketBytesDecoder sites))
            )


bucketBytesDecoder : List String -> BD.Decoder ( String, ( Int, Int ) )
bucketBytesDecoder sites =
    BD.map3 (\siteIdx inc dec -> ( siteAt siteIdx sites, ( inc, dec ) ))
        Wire.varintDecoder
        Wire.varintDecoder
        Wire.varintDecoder


encodeOpBytes : Op -> BE.Encoder
encodeOpBytes op =
    case op of
        Increment { site } ->
            BE.sequence [ BE.unsignedInt8 0, Wire.uuid site ]

        Decrement { site } ->
            BE.sequence [ BE.unsignedInt8 1, Wire.uuid site ]


opBytesDecoder : BD.Decoder Op
opBytesDecoder =
    BD.unsignedInt8
        |> BD.andThen
            (\tag ->
                case tag of
                    0 ->
                        BD.map (\site -> Increment { site = site }) Wire.uuidDecoder

                    1 ->
                        BD.map (\site -> Decrement { site = site }) Wire.uuidDecoder

                    _ ->
                        BD.fail
            )


collectSites : { r | site : String, buckets : Dict String ( Int, Int ) } -> List String
collectSites c =
    (c.site :: Dict.keys c.buckets) |> Set.fromList |> Set.toList


siteIndex : List String -> String -> Int
siteIndex table site =
    siteIndexHelp table site 0


siteIndexHelp : List String -> String -> Int -> Int
siteIndexHelp table site i =
    case table of
        [] ->
            -- Unreachable in practice: collectSites always includes every
            -- site siteIndex is ever called with. Falls back to 0 (silently
            -- wrong, not a crash) if that invariant is ever violated.
            0

        s :: rest ->
            if s == site then
                i

            else
                siteIndexHelp rest site (i + 1)


siteAt : Int -> List String -> String
siteAt idx table =
    List.drop idx table |> List.head |> Maybe.withDefault ""
