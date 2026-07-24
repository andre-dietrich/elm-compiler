module Crdt.Counter exposing (Counter, Op(..), init, value, siteCount, increment, decrement, applyOp, merge, encode, decoder, encodeOp, opDecoder)

import Dict exposing (Dict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


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
