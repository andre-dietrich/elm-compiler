module Crdt.Set exposing
    ( Set, Op(..)
    , init, toList, member, size
    , insert, remove, applyOp
    , sync
    , encode, decoder, encodeOp, opDecoder
    )

{-| Observed-Remove Set, API-shaped like `elm/core`'s `Set` (`sync` instead
of `merge` to avoid colliding with `elm/core`'s unrelated `Set.merge`
semantics). Add-wins: if an element is concurrently added on one site and
removed on another, the add survives once the two sites see each other.

`adds`/`removes` (the full tag history) is the CRDT source of truth and
never shrinks. `live` is a cached, incrementally-maintained view of "which
elements are currently visible" so `toList`/`member`/`size` don't rescan
the whole tag history on every call the way the very first version did
(that was O(current size) per element per read, i.e. quadratic in `toList`
over the set's lifetime). `insert`/local `remove`/remote `Add` update
`live` in O(log n) directly, since those cases are locally unambiguous;
only a remote `Remove` needs to actually recheck the affected element(s)
against the full tag history (an add this replica already knows about, that
the remover didn't, can keep the element alive).
-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Set as CoreSet


type Set comparable
    = Set
        { site : String
        , clock : Int
        , adds : CoreSet.Set ( String, comparable, Int )
        , removes : CoreSet.Set ( String, comparable, Int )
        , live : CoreSet.Set comparable
        }


type Op comparable
    = Add { site : String, element : comparable, tag : Int }
    | Remove { tags : List ( String, comparable, Int ) }


init : String -> Set comparable
init site =
    Set { site = site, clock = 0, adds = CoreSet.empty, removes = CoreSet.empty, live = CoreSet.empty }


insert : comparable -> Set comparable -> ( Set comparable, Op comparable )
insert element (Set s) =
    let
        tag =
            s.clock + 1
    in
    ( Set
        { s
            | clock = tag
            , adds = CoreSet.insert ( s.site, element, tag ) s.adds
            , live = CoreSet.insert element s.live
        }
    , Add { site = s.site, element = element, tag = tag }
    )


remove : comparable -> Set comparable -> ( Set comparable, Op comparable )
remove element (Set s) =
    let
        observed =
            CoreSet.filter (\( _, el, _ ) -> el == element) s.adds |> CoreSet.toList
    in
    ( Set
        { s
            | removes = CoreSet.union (CoreSet.fromList observed) s.removes
            , live = CoreSet.remove element s.live
        }
    , Remove { tags = observed }
    )


applyOp : Op comparable -> Set comparable -> Set comparable
applyOp op (Set s) =
    case op of
        Add { site, element, tag } ->
            Set
                { s
                    | adds = CoreSet.insert ( site, element, tag ) s.adds
                    , live = CoreSet.insert element s.live
                }

        Remove { tags } ->
            let
                newRemoves =
                    CoreSet.union (CoreSet.fromList tags) s.removes

                affectedElements =
                    tags |> List.map (\( _, el, _ ) -> el) |> CoreSet.fromList |> CoreSet.toList

                newLive =
                    List.foldl
                        (\element liveAcc ->
                            if hasLiveTag element s.adds newRemoves then
                                CoreSet.insert element liveAcc

                            else
                                CoreSet.remove element liveAcc
                        )
                        s.live
                        affectedElements
            in
            Set { s | removes = newRemoves, live = newLive }


hasLiveTag : comparable -> CoreSet.Set ( String, comparable, Int ) -> CoreSet.Set ( String, comparable, Int ) -> Bool
hasLiveTag element adds removes =
    CoreSet.filter (\( _, el, _ ) -> el == element) adds
        |> CoreSet.toList
        |> List.any (\tag -> not (CoreSet.member tag removes))


member : comparable -> Set comparable -> Bool
member element (Set s) =
    CoreSet.member element s.live


toList : Set comparable -> List comparable
toList (Set s) =
    CoreSet.toList s.live


size : Set comparable -> Int
size (Set s) =
    CoreSet.size s.live


{-| Bootstrap-only (see `Crdt.List.sync`'s doc for why this doesn't need to
be fast): `live` can't just be unioned from both sides' caches -- if A
still thinks a tag is live but B independently tombstoned that exact same
tag, unioning the caches would wrongly resurrect it. So `live` is fully
recomputed from the merged tag history here, same as the very first
(pre-cache) implementation did on every read.
-}
sync : Set comparable -> Set comparable -> Set comparable
sync (Set a) (Set b) =
    let
        mergedAdds =
            CoreSet.union a.adds b.adds

        mergedRemoves =
            CoreSet.union a.removes b.removes
    in
    Set
        { site = a.site
        , clock = max a.clock b.clock
        , adds = mergedAdds
        , removes = mergedRemoves
        , live = computeLive mergedAdds mergedRemoves
        }


computeLive : CoreSet.Set ( String, comparable, Int ) -> CoreSet.Set ( String, comparable, Int ) -> CoreSet.Set comparable
computeLive adds removes =
    CoreSet.diff adds removes
        |> CoreSet.toList
        |> List.map (\( _, el, _ ) -> el)
        |> CoreSet.fromList


encode : (comparable -> Encode.Value) -> Set comparable -> Encode.Value
encode encodeElement (Set s) =
    Encode.object
        [ ( "site", Encode.string s.site )
        , ( "clock", Encode.int s.clock )
        , ( "adds", Encode.list (encodeTag encodeElement) (CoreSet.toList s.adds) )
        , ( "removes", Encode.list (encodeTag encodeElement) (CoreSet.toList s.removes) )
        ]


decoder : Decoder comparable -> Decoder (Set comparable)
decoder elementDecoder =
    Decode.map4
        (\site clock addsList removesList ->
            let
                adds =
                    CoreSet.fromList addsList

                removes =
                    CoreSet.fromList removesList
            in
            Set { site = site, clock = clock, adds = adds, removes = removes, live = computeLive adds removes }
        )
        (Decode.field "site" Decode.string)
        (Decode.field "clock" Decode.int)
        (Decode.field "adds" (Decode.list (tagDecoder elementDecoder)))
        (Decode.field "removes" (Decode.list (tagDecoder elementDecoder)))


encodeOp : (comparable -> Encode.Value) -> Op comparable -> Encode.Value
encodeOp encodeElement op =
    case op of
        Add { site, element, tag } ->
            Encode.object
                [ ( "kind", Encode.string "add" )
                , ( "site", Encode.string site )
                , ( "element", encodeElement element )
                , ( "tag", Encode.int tag )
                ]

        Remove { tags } ->
            Encode.object
                [ ( "kind", Encode.string "remove" )
                , ( "tags", Encode.list (encodeTag encodeElement) tags )
                ]


opDecoder : Decoder comparable -> Decoder (Op comparable)
opDecoder elementDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "add" ->
                        Decode.map3 (\site element tag -> Add { site = site, element = element, tag = tag })
                            (Decode.field "site" Decode.string)
                            (Decode.field "element" elementDecoder)
                            (Decode.field "tag" Decode.int)

                    "remove" ->
                        Decode.map (\tags -> Remove { tags = tags })
                            (Decode.field "tags" (Decode.list (tagDecoder elementDecoder)))

                    _ ->
                        Decode.fail ("unknown Set.Op kind: " ++ kind)
            )


encodeTag : (comparable -> Encode.Value) -> ( String, comparable, Int ) -> Encode.Value
encodeTag encodeElement ( site, element, tag ) =
    Encode.list identity [ Encode.string site, encodeElement element, Encode.int tag ]


tagDecoder : Decoder comparable -> Decoder ( String, comparable, Int )
tagDecoder elementDecoder =
    Decode.map3 (\site element tag -> ( site, element, tag ))
        (Decode.index 0 Decode.string)
        (Decode.index 1 elementDecoder)
        (Decode.index 2 Decode.int)
