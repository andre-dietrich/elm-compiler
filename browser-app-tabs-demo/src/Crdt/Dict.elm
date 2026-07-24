module Crdt.Dict exposing
    ( Dict, Op(..)
    , init, get, keys, toList, size, historySize
    , insert, remove, applyOp
    , sync
    , encode, decoder, encodeOp, opDecoder
    )

{-| Observed-Remove Dict, API-shaped like `elm/core`'s `Dict` (`sync`
instead of `merge`, since `elm/core`'s `Dict.merge` is an unrelated
three-way combinator). `insert`/`remove`/`get` have the same signatures as
`elm/core`'s `Dict`, so `import Crdt.Dict as Dict` reads like ordinary Elm.
On a key that was written concurrently on two sites, the higher tag wins
(LWW-ish per key); presence itself is add-wins (Observed-Remove).

`adds`/`removes` (the full tag history) is the CRDT source of truth and
never shrinks. `liveKeys` is a cached, incrementally-maintained view of
"which keys are currently visible" so `get`/`keys`/`toList`/`size` don't
rescan the whole tag history on every call (the original version did this
per key on every read, i.e. quadratic in `toList` over the dict's
lifetime). `insert`/local `remove`/remote `Add` update `liveKeys` in
O(log n) directly; only a remote `Remove` needs to recheck the affected
key(s) against the full tag history (an add this replica already knows
about, that the remover didn't, can keep the key alive).
-}

import Dict as InternalDict
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Set as CoreSet


type Dict comparable v
    = Dict
        { site : String
        , clock : Int
        , adds : CoreSet.Set ( String, comparable, Int )
        , entries : InternalDict.Dict comparable ( v, Int )
        , removes : CoreSet.Set ( String, comparable, Int )
        , liveKeys : CoreSet.Set comparable
        }


type Op comparable v
    = Add { site : String, key : comparable, value : v, tag : Int }
    | Remove { tags : List ( String, comparable, Int ) }


init : String -> Dict comparable v
init site =
    Dict
        { site = site
        , clock = 0
        , adds = CoreSet.empty
        , entries = InternalDict.empty
        , removes = CoreSet.empty
        , liveKeys = CoreSet.empty
        }


insert : comparable -> v -> Dict comparable v -> ( Dict comparable v, Op comparable v )
insert key val (Dict d) =
    let
        tag =
            d.clock + 1
    in
    ( Dict
        { d
            | clock = tag
            , adds = CoreSet.insert ( d.site, key, tag ) d.adds
            , entries = InternalDict.insert key ( val, tag ) d.entries
            , liveKeys = CoreSet.insert key d.liveKeys
        }
    , Add { site = d.site, key = key, value = val, tag = tag }
    )


remove : comparable -> Dict comparable v -> ( Dict comparable v, Op comparable v )
remove key (Dict d) =
    let
        observed =
            CoreSet.filter (\( _, k, _ ) -> k == key) d.adds |> CoreSet.toList
    in
    ( Dict
        { d
            | removes = CoreSet.union (CoreSet.fromList observed) d.removes
            , liveKeys = CoreSet.remove key d.liveKeys
        }
    , Remove { tags = observed }
    )


applyOp : Op comparable v -> Dict comparable v -> Dict comparable v
applyOp op (Dict d) =
    case op of
        Add { site, key, value, tag } ->
            Dict
                { d
                    | adds = CoreSet.insert ( site, key, tag ) d.adds
                    , entries = InternalDict.update key (keepHigherTag value tag) d.entries
                    , liveKeys = CoreSet.insert key d.liveKeys
                }

        Remove { tags } ->
            let
                newRemoves =
                    CoreSet.union (CoreSet.fromList tags) d.removes

                affectedKeys =
                    tags |> List.map (\( _, k, _ ) -> k) |> CoreSet.fromList |> CoreSet.toList

                newLiveKeys =
                    List.foldl
                        (\key liveAcc ->
                            if hasLiveTag key d.adds newRemoves then
                                CoreSet.insert key liveAcc

                            else
                                CoreSet.remove key liveAcc
                        )
                        d.liveKeys
                        affectedKeys
            in
            Dict { d | removes = newRemoves, liveKeys = newLiveKeys }


hasLiveTag : comparable -> CoreSet.Set ( String, comparable, Int ) -> CoreSet.Set ( String, comparable, Int ) -> Bool
hasLiveTag key adds removes =
    CoreSet.filter (\( _, k, _ ) -> k == key) adds
        |> CoreSet.toList
        |> List.any (\tag -> not (CoreSet.member tag removes))


keepHigherTag : v -> Int -> Maybe ( v, Int ) -> Maybe ( v, Int )
keepHigherTag value tag existing =
    case existing of
        Just ( _, existingTag ) ->
            if tag >= existingTag then
                Just ( value, tag )

            else
                existing

        Nothing ->
            Just ( value, tag )


get : comparable -> Dict comparable v -> Maybe v
get key (Dict d) =
    if CoreSet.member key d.liveKeys then
        InternalDict.get key d.entries |> Maybe.map Tuple.first

    else
        Nothing


keys : Dict comparable v -> List comparable
keys (Dict d) =
    CoreSet.toList d.liveKeys


toList : Dict comparable v -> List ( comparable, v )
toList (Dict d) =
    CoreSet.toList d.liveKeys
        |> List.filterMap (\key -> InternalDict.get key d.entries |> Maybe.map (\( value, _ ) -> ( key, value )))


size : Dict comparable v -> Int
size (Dict d) =
    CoreSet.size d.liveKeys


{-| Total number of add-tags ever recorded, tombstoned or not -- shows the
tombstone accumulation that `size` (live-only) hides.
-}
historySize : Dict comparable v -> Int
historySize (Dict d) =
    CoreSet.size d.adds


{-| Bootstrap-only (see `Crdt.List.sync`'s doc for why this doesn't need to
be fast): `liveKeys` can't just be unioned from both sides' caches -- if A
still thinks a key is live but B independently tombstoned that exact tag,
unioning the caches would wrongly resurrect it. So `liveKeys` is fully
recomputed from the merged tag history here, same as the original
(pre-cache) implementation did on every read.
-}
sync : Dict comparable v -> Dict comparable v -> Dict comparable v
sync (Dict a) (Dict b) =
    let
        mergedAdds =
            CoreSet.union a.adds b.adds

        mergedRemoves =
            CoreSet.union a.removes b.removes

        mergedEntries =
            InternalDict.merge
                InternalDict.insert
                (\key va vb acc -> InternalDict.insert key (if Tuple.second va >= Tuple.second vb then va else vb) acc)
                InternalDict.insert
                a.entries
                b.entries
                InternalDict.empty
    in
    Dict
        { site = a.site
        , clock = max a.clock b.clock
        , adds = mergedAdds
        , removes = mergedRemoves
        , entries = mergedEntries
        , liveKeys = computeLiveKeys mergedAdds mergedRemoves
        }


computeLiveKeys : CoreSet.Set ( String, comparable, Int ) -> CoreSet.Set ( String, comparable, Int ) -> CoreSet.Set comparable
computeLiveKeys adds removes =
    CoreSet.diff adds removes
        |> CoreSet.toList
        |> List.map (\( _, k, _ ) -> k)
        |> CoreSet.fromList


encode : (comparable -> Encode.Value) -> (v -> Encode.Value) -> Dict comparable v -> Encode.Value
encode encodeKey encodeValue (Dict d) =
    Encode.object
        [ ( "site", Encode.string d.site )
        , ( "clock", Encode.int d.clock )
        , ( "adds", Encode.list (encodeTag encodeKey) (CoreSet.toList d.adds) )
        , ( "removes", Encode.list (encodeTag encodeKey) (CoreSet.toList d.removes) )
        , ( "entries", Encode.list (encodeEntry encodeKey encodeValue) (InternalDict.toList d.entries) )
        ]


decoder : Decoder comparable -> Decoder v -> Decoder (Dict comparable v)
decoder keyDecoder valueDecoder =
    Decode.map5
        (\site clock addsList removesList entriesList ->
            let
                adds =
                    CoreSet.fromList addsList

                removes =
                    CoreSet.fromList removesList
            in
            Dict
                { site = site
                , clock = clock
                , adds = adds
                , removes = removes
                , entries = InternalDict.fromList entriesList
                , liveKeys = computeLiveKeys adds removes
                }
        )
        (Decode.field "site" Decode.string)
        (Decode.field "clock" Decode.int)
        (Decode.field "adds" (Decode.list (tagDecoder keyDecoder)))
        (Decode.field "removes" (Decode.list (tagDecoder keyDecoder)))
        (Decode.field "entries" (Decode.list (entryDecoder keyDecoder valueDecoder)))


encodeOp : (comparable -> Encode.Value) -> (v -> Encode.Value) -> Op comparable v -> Encode.Value
encodeOp encodeKey encodeValue op =
    case op of
        Add { site, key, value, tag } ->
            Encode.object
                [ ( "kind", Encode.string "add" )
                , ( "site", Encode.string site )
                , ( "key", encodeKey key )
                , ( "value", encodeValue value )
                , ( "tag", Encode.int tag )
                ]

        Remove { tags } ->
            Encode.object
                [ ( "kind", Encode.string "remove" )
                , ( "tags", Encode.list (encodeTag encodeKey) tags )
                ]


opDecoder : Decoder comparable -> Decoder v -> Decoder (Op comparable v)
opDecoder keyDecoder valueDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "add" ->
                        Decode.map4 (\site key value tag -> Add { site = site, key = key, value = value, tag = tag })
                            (Decode.field "site" Decode.string)
                            (Decode.field "key" keyDecoder)
                            (Decode.field "value" valueDecoder)
                            (Decode.field "tag" Decode.int)

                    "remove" ->
                        Decode.map (\tags -> Remove { tags = tags })
                            (Decode.field "tags" (Decode.list (tagDecoder keyDecoder)))

                    _ ->
                        Decode.fail ("unknown Dict.Op kind: " ++ kind)
            )


encodeTag : (comparable -> Encode.Value) -> ( String, comparable, Int ) -> Encode.Value
encodeTag encodeKey ( site, key, tag ) =
    Encode.list identity [ Encode.string site, encodeKey key, Encode.int tag ]


tagDecoder : Decoder comparable -> Decoder ( String, comparable, Int )
tagDecoder keyDecoder =
    Decode.map3 (\site key tag -> ( site, key, tag ))
        (Decode.index 0 Decode.string)
        (Decode.index 1 keyDecoder)
        (Decode.index 2 Decode.int)


encodeEntry : (comparable -> Encode.Value) -> (v -> Encode.Value) -> ( comparable, ( v, Int ) ) -> Encode.Value
encodeEntry encodeKey encodeValue ( key, ( value, tag ) ) =
    Encode.object [ ( "key", encodeKey key ), ( "value", encodeValue value ), ( "tag", Encode.int tag ) ]


entryDecoder : Decoder comparable -> Decoder v -> Decoder ( comparable, ( v, Int ) )
entryDecoder keyDecoder valueDecoder =
    Decode.map3 (\key value tag -> ( key, ( value, tag ) ))
        (Decode.field "key" keyDecoder)
        (Decode.field "value" valueDecoder)
        (Decode.field "tag" Decode.int)
