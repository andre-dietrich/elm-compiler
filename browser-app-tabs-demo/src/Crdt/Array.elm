module Crdt.Array exposing
    ( Array, Op
    , init, get, toList, length
    , push, insertAt, removeAt, applyOp
    , sync
    , encode, decoder, encodeOp, opDecoder
    )

{-| Thin `elm/core`-`Array`-flavoured wrapper around `Crdt.List`. A CRDT
sequence's position is logical (tree-based), not a literal array index, so
there is no atomic "set at index" the way `Array.set` has -- do a
`removeAt` followed by `insertAt` (two ops) if you need to replace an
element in place. For genuinely large collections needing fast indexed
access, `Crdt.List`'s O(visible-length) traversal-based indexing (see its
docs) would need a proper indexed tree structure first; this wrapper
doesn't change that.
-}

import Crdt.List as CrdtList
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)


type alias Array a =
    CrdtList.Sequence a


type alias Op a =
    CrdtList.Op a


init : String -> Array a
init =
    CrdtList.init


get : Int -> Array a -> Maybe a
get =
    CrdtList.get


toList : Array a -> List a
toList =
    CrdtList.toList


length : Array a -> Int
length =
    CrdtList.length


push : a -> Array a -> ( Array a, Op a )
push value array =
    CrdtList.insertAt (length array) value array


insertAt : Int -> a -> Array a -> ( Array a, Op a )
insertAt =
    CrdtList.insertAt


removeAt : Int -> Array a -> Maybe ( Array a, Op a )
removeAt =
    CrdtList.removeAt


applyOp : Op a -> Array a -> Array a
applyOp =
    CrdtList.applyOp


sync : Array a -> Array a -> Array a
sync =
    CrdtList.sync


encode : (a -> Value) -> Array a -> Value
encode =
    CrdtList.encode


decoder : Decoder a -> Decoder (Array a)
decoder =
    CrdtList.decoder


encodeOp : (a -> Value) -> Op a -> Value
encodeOp =
    CrdtList.encodeOp


opDecoder : Decoder a -> Decoder (Op a)
opDecoder =
    CrdtList.opDecoder
