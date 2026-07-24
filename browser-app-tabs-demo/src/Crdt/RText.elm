module Crdt.RText exposing
    ( RText, Op
    , init, withSite, toString, length, nodeCount
    , insertChar, insertString, removeChar, applyOp
    , sync
    , encode, decoder, encodeOp, opDecoder
    )

{-| Character-level CRDT text -- `Crdt.List` specialized to `Char`, plus
`String` conversions. Inherits `Crdt.List`'s Fugue-based, interleaving-
resistant ordering.
-}

import Crdt.List as CrdtList
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type alias RText =
    CrdtList.Sequence Char


type alias Op =
    CrdtList.Op Char


init : String -> RText
init =
    CrdtList.init


withSite : String -> RText -> RText
withSite =
    CrdtList.withSite


toString : RText -> String
toString rtext =
    CrdtList.toList rtext |> String.fromList


length : RText -> Int
length =
    CrdtList.length


nodeCount : RText -> Int
nodeCount =
    CrdtList.nodeCount


insertChar : Int -> Char -> RText -> ( RText, Op )
insertChar =
    CrdtList.insertAt


{-| Insert a whole string at a character position -- convenience for e.g.
paste. Fugue has no batch-insert primitive, so this produces one op per
character, applied left-to-right so the pasted run stays contiguous (each
character's left neighbour is the one just inserted before it).
-}
insertString : Int -> String -> RText -> ( RText, List Op )
insertString index str rtext =
    String.toList str
        |> List.foldl
            (\char ( acc, offset, ops ) ->
                let
                    ( newAcc, op ) =
                        CrdtList.insertAt (index + offset) char acc
                in
                ( newAcc, offset + 1, op :: ops )
            )
            ( rtext, 0, [] )
        |> (\( acc, _, ops ) -> ( acc, List.reverse ops ))


removeChar : Int -> RText -> Maybe ( RText, Op )
removeChar =
    CrdtList.removeAt


applyOp : Op -> RText -> RText
applyOp =
    CrdtList.applyOp


sync : RText -> RText -> RText
sync =
    CrdtList.sync


encode : RText -> Encode.Value
encode =
    CrdtList.encode encodeChar


decoder : Decoder RText
decoder =
    CrdtList.decoder charDecoder


encodeOp : Op -> Encode.Value
encodeOp =
    CrdtList.encodeOp encodeChar


opDecoder : Decoder Op
opDecoder =
    CrdtList.opDecoder charDecoder


encodeChar : Char -> Encode.Value
encodeChar char =
    Encode.string (String.fromChar char)


charDecoder : Decoder Char
charDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case String.toList s of
                    [ c ] ->
                        Decode.succeed c

                    _ ->
                        Decode.fail "expected a single character"
            )
