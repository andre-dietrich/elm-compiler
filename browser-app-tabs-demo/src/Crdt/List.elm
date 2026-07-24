module Crdt.List exposing
    ( Sequence, Op(..)
    , init, withSite, get, toList, length, nodeCount
    , insertAt, removeAt, applyOp
    , sync
    , encode, decoder, encodeOp, opDecoder
    )

{-| Ordered CRDT sequence using the Fugue algorithm (Weidner, Kleppmann,
Gentle 2023, "The Art of the Fugue: Minimizing Interleaving in
Collaborative Text Editing"). Ported from the authors' own reference
implementation (github.com/mweidner037/fugue, `fugue-simple/src/index.ts`)
to keep the tie-break rule and tree-linking logic exactly as specified,
rather than a from-memory reconstruction of plain RGA (which has a known
interleaving anomaly this algorithm specifically avoids).

Each inserted element becomes a node in a tree: `parent` + `side` (L/R)
place it relative to its neighbours at insertion time. That tree is the
source of truth for CRDT correctness and is untouched by the concerns
below; only how it gets *read*, and what a deleted node retains, differs
from the simplest possible port:

  - Linearizing the tree (left children, self, right children) is done
    with an explicit, tail-recursive work-list instead of native recursion,
    so it compiles to a loop (Elm guarantees tail-call elimination) rather
    than growing the call stack per tree node. The reference implementation
    has the same native-recursion-overflows-the-stack problem in JS (its
    own comment: "overflows the stack at modest depths (~4000)") and fixes
    it the same way, manually, because JS engines don't guarantee TCO.
  - The flattened order is cached on the `Sequence` value and only
    recomputed when the tree structure actually changes (insert), not on
    every read -- `toList`/`get`/`length` are then just a filter over the
    cached id list, not a full re-walk.
  - Deleted elements become tombstones (kept, not removed -- they can still
    serve as position anchors for later concurrent inserts), but a
    tombstone's *content* is garbage-collected immediately, the way Yjs's
    default `doc.gc = true` behaviour works: `Node.value` is `Nothing` for
    a deleted node, keeping only what future position computations still
    need (id/parent/side/children), discarding the payload. This is safe
    unconditionally here (no "wait until all peers have acknowledged"
    caveat needed) because `determineParentSide`/`leftmostDescendant` --
    the only things that ever read the tree -- never look at a node's
    value, deleted or not; and because list/text deletes are permanent in
    this CRDT (no add-wins "undelete" the way `Crdt.Set`/`Crdt.Dict` have),
    so a tombstone's value can never legitimately be needed again by
    anyone. `sync`'s merge rule reflects that: if either replica has
    already deleted an id, the merged node has no value, regardless of
    whether the other replica has caught up yet.
  - There's no `doc.gc = false`-equivalent escape hatch (Yjs offers one for
    undo/history features that need the deleted content back) -- add one
    if this ever grows an undo feature; until then it would be unused
    flexibility.
  - `encode`/`decoder` (the full-state bootstrap wire format) intern site
    ids: every distinct site UUID appearing anywhere in the tree (a node's
    own id, its parent, every id in every children list) is written once
    into a `"sites"` table, and every reference elsewhere in the payload is
    a short integer index into that table instead of the repeated 36-
    character UUID string. This matters more than the payload GC above did
    in practice: a node's *structural* overhead (its own id + parent id +
    however many children ids) turned out to dwarf a single character's
    payload, so shrinking that repetition is the bigger win. `encodeOp`/
    `opDecoder` (the small, frequent per-keystroke messages) deliberately
    keep plain UUID strings -- a single op only ever references one or two
    sites, so a table there would add more JSON structure than it saves.

Known limitations (documented rather than silently accepted):
  - The tombstones' structural skeletons (id/parent/side/children) still
    accumulate forever -- GC only discards the payload, not the node
    entry itself, since the position bookkeeping is still needed. A
    sequence with heavy insert/delete churn still grows without bound,
    just slower than before.
  - `applyOp` assumes causally-ordered delivery (an insert's parent has
    already been applied before the insert itself arrives). BroadcastChannel
    delivery on a single origin is not a formal guarantee of this; out-of-
    order delivery would silently orphan the node until/unless a later
    `sync` (full-state) exchange repairs it.
-}

import Dict exposing (Dict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Set


type alias NodeId =
    ( String, Int )


type Side
    = L
    | R


type alias Node a =
    { value : Maybe a -- Nothing = deleted/GC'd (payload discarded); Just = live
    , parent : Maybe NodeId
    , side : Side
    , leftChildren : List NodeId
    , rightChildren : List NodeId
    }


type Sequence a
    = Sequence
        { site : String
        , clock : Int
        , nodes : Dict NodeId (Node a)
        , rootLeft : List NodeId
        , rootRight : List NodeId

        -- All ids (tombstones included) in tree order. Recomputed only when
        -- the tree structure changes (insert), reused as-is across deletes
        -- and reads.
        , order : List NodeId
        }


type Op a
    = InsertOp { id : NodeId, value : a, parent : Maybe NodeId, side : Side }
    | DeleteOp { id : NodeId }


init : String -> Sequence a
init site =
    Sequence { site = site, clock = 0, nodes = Dict.empty, rootLeft = [], rootRight = [], order = [] }


{-| Continue editing an existing sequence under a different site identity
(e.g. forking a replica for testing, or resuming a loaded document as a new
site). Only affects which id future local operations get; the tree itself
is unchanged.
-}
withSite : String -> Sequence a -> Sequence a
withSite newSite (Sequence l) =
    Sequence { l | site = newSite, clock = 0 }



-- READING


get : Int -> Sequence a -> Maybe a
get index seq =
    let
        (Sequence l) =
            seq
    in
    visibleIdList seq
        |> List.drop index
        |> List.head
        |> Maybe.andThen (\id -> Dict.get id l.nodes)
        |> Maybe.andThen .value


toList : Sequence a -> List a
toList seq =
    let
        (Sequence l) =
            seq
    in
    visibleIdList seq |> List.filterMap (\id -> Dict.get id l.nodes |> Maybe.andThen .value)


length : Sequence a -> Int
length seq =
    List.length (visibleIdList seq)


{-| Total nodes ever created, tombstoned or not -- the tree's actual
storage cost (structural skeletons don't get GC'd, only content does), which
`length` (visible-only) hides.
-}
nodeCount : Sequence a -> Int
nodeCount (Sequence l) =
    Dict.size l.nodes


visibleIdList : Sequence a -> List NodeId
visibleIdList (Sequence l) =
    List.filter (\id -> not (isDeleted l.nodes id)) l.order


isDeleted : Dict NodeId (Node a) -> NodeId -> Bool
isDeleted nodes id =
    case Dict.get id nodes of
        Just node ->
            node.value == Nothing

        Nothing ->
            True


{-| Flatten the tree (left children, self, right children, recursively)
into `order` using an explicit work-list on the heap instead of native call
recursion, so this is safe regardless of tree depth/shape. `go` is
self-tail-recursive, which Elm compiles to a loop.
-}
recomputeOrder : { r | nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId } -> List NodeId
recomputeOrder l =
    let
        initialWork =
            List.map VisitSubtree l.rootLeft ++ List.map VisitSubtree l.rootRight
    in
    flattenGo l.nodes initialWork []


type WorkItem
    = VisitSubtree NodeId
    | EmitSelf NodeId


flattenGo : Dict NodeId (Node a) -> List WorkItem -> List NodeId -> List NodeId
flattenGo nodes work acc =
    case work of
        [] ->
            List.reverse acc

        (EmitSelf id) :: rest ->
            flattenGo nodes rest (id :: acc)

        (VisitSubtree id) :: rest ->
            case Dict.get id nodes of
                Nothing ->
                    flattenGo nodes rest acc

                Just node ->
                    let
                        expanded =
                            List.map VisitSubtree node.leftChildren
                                ++ (EmitSelf id :: List.map VisitSubtree node.rightChildren)
                    in
                    flattenGo nodes (expanded ++ rest) acc



-- INSERT / DELETE (local)


insertAt : Int -> a -> Sequence a -> ( Sequence a, Op a )
insertAt visibleIndex value (Sequence l) =
    let
        id =
            ( l.site, l.clock )

        visibleIds =
            visibleIdList (Sequence l)

        clampedIndex =
            clamp 0 (List.length visibleIds) visibleIndex

        leftOrigin =
            if clampedIndex == 0 then
                Nothing

            else
                List.drop (clampedIndex - 1) visibleIds |> List.head

        ( parent, side ) =
            determineParentSide l leftOrigin

        linked =
            linkNode id { value = Just value, parent = parent, side = side, leftChildren = [], rightChildren = [] }
                { l | clock = l.clock + 1 }

        newL =
            { linked | order = recomputeOrder linked }
    in
    ( Sequence newL, InsertOp { id = id, value = value, parent = parent, side = side } )


{-| Deleting drops the payload immediately (GC, see module doc) but leaves
tree structure -- and therefore the `order` cache -- untouched, so this
doesn't need to recompute it.
-}
removeAt : Int -> Sequence a -> Maybe ( Sequence a, Op a )
removeAt visibleIndex seq =
    let
        (Sequence l) =
            seq
    in
    visibleIdList seq
        |> List.drop visibleIndex
        |> List.head
        |> Maybe.map
            (\id ->
                ( Sequence { l | nodes = Dict.update id (Maybe.map (\n -> { n | value = Nothing })) l.nodes }
                , DeleteOp { id = id }
                )
            )


{-| Given the node immediately to the left of the insertion point (or
`Nothing` for "insert at the very start"), decide the new node's parent and
side. This is the core Fugue rule: if the left neighbour has no right
children yet, the new node becomes its right child; otherwise it becomes
the left child of the leftmost descendant of the left neighbour's first
right child (i.e. the node that is currently immediately after it).
-}
determineParentSide :
    { r | nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId }
    -> Maybe NodeId
    -> ( Maybe NodeId, Side )
determineParentSide l leftOrigin =
    case childrenOf leftOrigin R l of
        [] ->
            ( leftOrigin, R )

        first :: _ ->
            ( Just (leftmostDescendant l.nodes first), L )


childrenOf : Maybe NodeId -> Side -> { r | nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId } -> List NodeId
childrenOf parent side l =
    case parent of
        Nothing ->
            if side == L then
                l.rootLeft

            else
                l.rootRight

        Just pid ->
            case Dict.get pid l.nodes of
                Just node ->
                    if side == L then
                        node.leftChildren

                    else
                        node.rightChildren

                Nothing ->
                    []


leftmostDescendant : Dict NodeId (Node a) -> NodeId -> NodeId
leftmostDescendant nodes id =
    case Dict.get id nodes of
        Just node ->
            case node.leftChildren of
                first :: _ ->
                    leftmostDescendant nodes first

                [] ->
                    id

        Nothing ->
            id


{-| Insert `newId`'s sibling position among same-(parent,side) nodes.
Siblings are kept sorted ascending by site id -- an id can only ever occupy
one same-(parent,side) slot per site (a site's own consecutive inserts
chain onto each other instead, per `determineParentSide`), so there is no
need to break ties by clock.
-}
insertSortedAsc : NodeId -> List NodeId -> List NodeId
insertSortedAsc newId siblings =
    case siblings of
        [] ->
            [ newId ]

        s :: rest ->
            if Tuple.first newId > Tuple.first s then
                s :: insertSortedAsc newId rest

            else
                newId :: siblings


linkNode :
    NodeId
    -> Node a
    -> { r | nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId }
    -> { r | nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId }
linkNode id node l =
    let
        nodesWithNew =
            Dict.insert id node l.nodes
    in
    case node.parent of
        Nothing ->
            if node.side == L then
                { l | nodes = nodesWithNew, rootLeft = insertSortedAsc id l.rootLeft }

            else
                { l | nodes = nodesWithNew, rootRight = insertSortedAsc id l.rootRight }

        Just pid ->
            case Dict.get pid nodesWithNew of
                Just pnode ->
                    let
                        updatedParent =
                            if node.side == L then
                                { pnode | leftChildren = insertSortedAsc id pnode.leftChildren }

                            else
                                { pnode | rightChildren = insertSortedAsc id pnode.rightChildren }
                    in
                    { l | nodes = Dict.insert pid updatedParent nodesWithNew }

                Nothing ->
                    -- Parent not seen locally yet (out-of-order delivery) -- node is
                    -- stored but stays unlinked/invisible until a `sync` repairs it.
                    { l | nodes = nodesWithNew }



-- REMOTE OPERATIONS


applyOp : Op a -> Sequence a -> Sequence a
applyOp op (Sequence l) =
    case op of
        InsertOp { id, value, parent, side } ->
            if Dict.member id l.nodes then
                Sequence l

            else
                let
                    linked =
                        linkNode id { value = Just value, parent = parent, side = side, leftChildren = [], rightChildren = [] } l
                in
                Sequence { linked | order = recomputeOrder linked }

        DeleteOp { id } ->
            Sequence { l | nodes = Dict.update id (Maybe.map (\n -> { n | value = Nothing })) l.nodes }



-- BOOTSTRAP SYNC


{-| Only used for the one-time bootstrap exchange when a tab joins. Unions
the two node sets and rebuilds the tree structure from scratch in a
two-pass, order-independent way, since `insertSortedAsc`'s comparator alone
determines final sibling order regardless of which node is linked first.

Merge rule for `value`: if *either* replica has already deleted (GC'd) an
id, the merged node has no value -- deletes are permanent here, so once
anyone has recorded one, it can't be un-done by the other replica simply
not having caught up yet.
-}
sync : Sequence a -> Sequence a -> Sequence a
sync (Sequence a) (Sequence b) =
    let
        mergedFlat =
            Dict.merge
                Dict.insert
                (\id na nb acc ->
                    Dict.insert id
                        { na
                            | value =
                                if na.value == Nothing || nb.value == Nothing then
                                    Nothing

                                else
                                    na.value
                        }
                        acc
                )
                Dict.insert
                a.nodes
                b.nodes
                Dict.empty

        cleared =
            Dict.map (\_ n -> { n | leftChildren = [], rightChildren = [] }) mergedFlat

        rebuilt =
            List.foldl (relink mergedFlat)
                { nodes = cleared, rootLeft = [], rootRight = [] }
                (Dict.keys mergedFlat)
    in
    Sequence
        { site = a.site
        , clock = max a.clock b.clock
        , nodes = rebuilt.nodes
        , rootLeft = rebuilt.rootLeft
        , rootRight = rebuilt.rootRight
        , order = recomputeOrder rebuilt
        }


relink :
    Dict NodeId (Node a)
    -> NodeId
    -> { nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId }
    -> { nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId }
relink original id acc =
    case Dict.get id original of
        Nothing ->
            acc

        Just node ->
            case node.parent of
                Nothing ->
                    if node.side == L then
                        { acc | rootLeft = insertSortedAsc id acc.rootLeft }

                    else
                        { acc | rootRight = insertSortedAsc id acc.rootRight }

                Just pid ->
                    { acc
                        | nodes =
                            Dict.update pid
                                (Maybe.map
                                    (\pnode ->
                                        if node.side == L then
                                            { pnode | leftChildren = insertSortedAsc id pnode.leftChildren }

                                        else
                                            { pnode | rightChildren = insertSortedAsc id pnode.rightChildren }
                                    )
                                )
                                acc.nodes
                    }



-- JSON
--
-- `order` is a pure cache and never serialized; `decoder` recomputes it
-- after decoding the raw tree fields. A GC'd node's `value` encodes as
-- `null`. `encode`/`decoder` additionally intern site ids into a `"sites"`
-- table (see module doc) -- every `NodeId`/`Maybe NodeId` in this section
-- encodes as a short index into that table instead of a repeated UUID
-- string.


{-| Every distinct site UUID referenced anywhere in the tree: this
sequence's own site, plus every node's id, parent id, and every id in every
children list. Order only needs to be consistent within one `encode` call
(the same table travels with the message the decoder reads it back from),
so a simple dedup via `Set` is enough.
-}
collectSites : { r | site : String, nodes : Dict NodeId (Node a), rootLeft : List NodeId, rootRight : List NodeId } -> List String
collectSites l =
    let
        siteOf ( site, _ ) =
            site

        nodeSites ( id, node ) =
            siteOf id
                :: (node.parent |> Maybe.map (siteOf >> List.singleton) |> Maybe.withDefault [])
                ++ List.map siteOf node.leftChildren
                ++ List.map siteOf node.rightChildren
    in
    (l.site :: List.concatMap nodeSites (Dict.toList l.nodes) ++ List.map siteOf l.rootLeft ++ List.map siteOf l.rootRight)
        |> Set.fromList
        |> Set.toList


siteIndex : List String -> String -> Int
siteIndex table site =
    siteIndexHelp table site 0


siteIndexHelp : List String -> String -> Int -> Int
siteIndexHelp table site i =
    case table of
        [] ->
            0

        s :: rest ->
            if s == site then
                i

            else
                siteIndexHelp rest site (i + 1)


siteAt : Int -> List String -> String
siteAt idx table =
    List.drop idx table |> List.head |> Maybe.withDefault ""


encodeNodeIdIndexed : List String -> NodeId -> Encode.Value
encodeNodeIdIndexed table ( site, counter ) =
    Encode.list identity [ Encode.int (siteIndex table site), Encode.int counter ]


nodeIdIndexedDecoder : List String -> Decoder NodeId
nodeIdIndexedDecoder table =
    Decode.map2 (\idx counter -> ( siteAt idx table, counter ))
        (Decode.index 0 Decode.int)
        (Decode.index 1 Decode.int)


encodeMaybeNodeIdIndexed : List String -> Maybe NodeId -> Encode.Value
encodeMaybeNodeIdIndexed table maybeId =
    case maybeId of
        Nothing ->
            Encode.null

        Just id ->
            encodeNodeIdIndexed table id


maybeNodeIdIndexedDecoder : List String -> Decoder (Maybe NodeId)
maybeNodeIdIndexedDecoder table =
    Decode.nullable (nodeIdIndexedDecoder table)


encodeNodeEntryIndexed : List String -> (a -> Encode.Value) -> ( NodeId, Node a ) -> Encode.Value
encodeNodeEntryIndexed table encodeValue ( id, node ) =
    Encode.object
        [ ( "id", encodeNodeIdIndexed table id )
        , ( "value", Maybe.map encodeValue node.value |> Maybe.withDefault Encode.null )
        , ( "parent", encodeMaybeNodeIdIndexed table node.parent )
        , ( "side", encodeSide node.side )
        , ( "leftChildren", Encode.list (encodeNodeIdIndexed table) node.leftChildren )
        , ( "rightChildren", Encode.list (encodeNodeIdIndexed table) node.rightChildren )
        ]


nodeEntryIndexedDecoder : List String -> Decoder a -> Decoder ( NodeId, Node a )
nodeEntryIndexedDecoder table valueDecoder =
    Decode.map6
        (\id value parent side leftChildren rightChildren ->
            ( id
            , { value = value
              , parent = parent
              , side = side
              , leftChildren = leftChildren
              , rightChildren = rightChildren
              }
            )
        )
        (Decode.field "id" (nodeIdIndexedDecoder table))
        (Decode.field "value" (Decode.nullable valueDecoder))
        (Decode.field "parent" (maybeNodeIdIndexedDecoder table))
        (Decode.field "side" sideDecoder)
        (Decode.field "leftChildren" (Decode.list (nodeIdIndexedDecoder table)))
        (Decode.field "rightChildren" (Decode.list (nodeIdIndexedDecoder table)))


encode : (a -> Encode.Value) -> Sequence a -> Encode.Value
encode encodeValue (Sequence l) =
    let
        sites =
            collectSites l
    in
    Encode.object
        [ ( "sites", Encode.list Encode.string sites )
        , ( "site", Encode.int (siteIndex sites l.site) )
        , ( "clock", Encode.int l.clock )
        , ( "nodes", Encode.list (encodeNodeEntryIndexed sites encodeValue) (Dict.toList l.nodes) )
        , ( "rootLeft", Encode.list (encodeNodeIdIndexed sites) l.rootLeft )
        , ( "rootRight", Encode.list (encodeNodeIdIndexed sites) l.rootRight )
        ]


decoder : Decoder a -> Decoder (Sequence a)
decoder valueDecoder =
    Decode.field "sites" (Decode.list Decode.string)
        |> Decode.andThen
            (\sites ->
                Decode.map5
                    (\siteIdx clock nodesList rootLeft rootRight ->
                        let
                            raw =
                                { site = siteAt siteIdx sites
                                , clock = clock
                                , nodes = Dict.fromList nodesList
                                , rootLeft = rootLeft
                                , rootRight = rootRight
                                , order = []
                                }
                        in
                        Sequence { raw | order = recomputeOrder raw }
                    )
                    (Decode.field "site" Decode.int)
                    (Decode.field "clock" Decode.int)
                    (Decode.field "nodes" (Decode.list (nodeEntryIndexedDecoder sites valueDecoder)))
                    (Decode.field "rootLeft" (Decode.list (nodeIdIndexedDecoder sites)))
                    (Decode.field "rootRight" (Decode.list (nodeIdIndexedDecoder sites)))
            )


encodeOp : (a -> Encode.Value) -> Op a -> Encode.Value
encodeOp encodeValue op =
    case op of
        InsertOp { id, value, parent, side } ->
            Encode.object
                [ ( "kind", Encode.string "insert" )
                , ( "id", encodeNodeId id )
                , ( "value", encodeValue value )
                , ( "parent", encodeMaybeNodeId parent )
                , ( "side", encodeSide side )
                ]

        DeleteOp { id } ->
            Encode.object
                [ ( "kind", Encode.string "delete" )
                , ( "id", encodeNodeId id )
                ]


opDecoder : Decoder a -> Decoder (Op a)
opDecoder valueDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "insert" ->
                        Decode.map4 (\id value parent side -> InsertOp { id = id, value = value, parent = parent, side = side })
                            (Decode.field "id" nodeIdDecoder)
                            (Decode.field "value" valueDecoder)
                            (Decode.field "parent" maybeNodeIdDecoder)
                            (Decode.field "side" sideDecoder)

                    "delete" ->
                        Decode.map (\id -> DeleteOp { id = id }) (Decode.field "id" nodeIdDecoder)

                    _ ->
                        Decode.fail ("unknown Crdt.List.Op kind: " ++ kind)
            )


encodeNodeId : NodeId -> Encode.Value
encodeNodeId ( site, counter ) =
    Encode.list identity [ Encode.string site, Encode.int counter ]


nodeIdDecoder : Decoder NodeId
nodeIdDecoder =
    Decode.map2 Tuple.pair (Decode.index 0 Decode.string) (Decode.index 1 Decode.int)


encodeMaybeNodeId : Maybe NodeId -> Encode.Value
encodeMaybeNodeId maybeId =
    case maybeId of
        Nothing ->
            Encode.null

        Just id ->
            encodeNodeId id


maybeNodeIdDecoder : Decoder (Maybe NodeId)
maybeNodeIdDecoder =
    Decode.nullable nodeIdDecoder


encodeSide : Side -> Encode.Value
encodeSide side =
    Encode.string
        (if side == L then
            "L"

         else
            "R"
        )


sideDecoder : Decoder Side
sideDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case s of
                    "L" ->
                        Decode.succeed L

                    "R" ->
                        Decode.succeed R

                    _ ->
                        Decode.fail ("unknown Side: " ++ s)
            )
