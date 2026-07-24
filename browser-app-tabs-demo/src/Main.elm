module Main exposing (main)

import Browser
import Browser.Navigation as Nav
import Bytes
import Bytes.Encode as BE
import Crdt.Counter as Counter
import Crdt.Dict as CrdtDict
import Crdt.LWW as LWW
import Crdt.RText as RText
import Crdt.Sync exposing (WireMsg(..))
import Html exposing (Html, a, button, code, div, h1, h2, input, li, p, pre, text, textarea, ul)
import Html.Attributes exposing (href, placeholder, value)
import Html.Events exposing (onClick, onInput)
import Shared exposing (SharedOp(..), SharedState)
import Shared.Binary
import Shared.Json
import Url exposing (Url)


{-| The entire codec switch: change this line (and nothing else) to
`Shared.Json.codec` to go back to JSON. See
docs/superpowers/specs/2026-07-24-bytes-wire-protocol-design.md.
All open tabs must run the same codec; switching requires reloading every
open tab to match (a tab on Binary cannot talk to one on Json).
-}
codec : Crdt.Sync.Codec
codec =
    Shared.Binary.codec



-- MODEL


type Tab
    = Overview
    | Settings
    | Reports


type alias Model =
    { key : Nav.Key
    , tab : Tab
    , shared : SharedState
    , draftTag : String
    , lastSentOpBytes : Int
    }


init : String -> Url -> Nav.Key -> ( Model, Cmd Msg )
init site url key =
    ( { key = key
      , tab = tabFromUrl url
      , shared = Shared.init site
      , draftTag = ""
      , lastSentOpBytes = 0
      }
    , Cmd.none
    )


tabFromUrl : Url -> Tab
tabFromUrl url =
    case url.fragment of
        Just "settings" ->
            Settings

        Just "reports" ->
            Reports

        _ ->
            Overview



-- UPDATE


type Msg
    = UrlChanged Url
    | LinkClicked Browser.UrlRequest
    | Increment
    | Decrement
    | DraftTagChanged String
    | AddTag
    | RemoveTag String
    | TitleChanged String
    | NotesChanged String


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        UrlChanged url ->
            ( { model | tab = tabFromUrl url }, Cmd.none )

        LinkClicked request ->
            case request of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        Increment ->
            let
                ( newTotal, op ) =
                    Counter.increment model.shared.total

                shared =
                    model.shared
            in
            withSentOp (TotalOp op) { model | shared = { shared | total = newTotal } }

        Decrement ->
            let
                ( newTotal, op ) =
                    Counter.decrement model.shared.total

                shared =
                    model.shared
            in
            withSentOp (TotalOp op) { model | shared = { shared | total = newTotal } }

        DraftTagChanged text ->
            ( { model | draftTag = text }, Cmd.none )

        AddTag ->
            if String.isEmpty model.draftTag then
                ( model, Cmd.none )

            else
                let
                    ( newTags, op ) =
                        CrdtDict.insert model.draftTag True model.shared.tags

                    shared =
                        model.shared
                in
                withSentOp (TagsOp op) { model | shared = { shared | tags = newTags }, draftTag = "" }

        RemoveTag tag ->
            let
                ( newTags, op ) =
                    CrdtDict.remove tag model.shared.tags

                shared =
                    model.shared
            in
            withSentOp (TagsOp op) { model | shared = { shared | tags = newTags } }

        TitleChanged text ->
            let
                ( newTitle, op ) =
                    LWW.set text model.shared.title

                shared =
                    model.shared
            in
            withSentOp (TitleOp op) { model | shared = { shared | title = newTitle } }

        NotesChanged newText ->
            let
                ( newNotes, ops ) =
                    applyTextDiff (RText.toString model.shared.notes) newText model.shared.notes

                shared =
                    model.shared
            in
            withSentOps (List.map NotesOp ops) { model | shared = { shared | notes = newNotes } }


{-| Records an op's encoded size (for the stats panel) and sends it. Every
mutating `Msg` branch above updates `model.shared` first, then pipes the
result through here -- this is the only place that touches
`Crdt.Sync.send`/encoding in `Main.elm`.
-}
withSentOp : SharedOp -> Model -> ( Model, Cmd Msg )
withSentOp op model =
    withSentOps [ op ] model


withSentOps : List SharedOp -> Model -> ( Model, Cmd Msg )
withSentOps ops model =
    let
        totalBytes =
            ops |> List.map (\op -> BE.encode (codec.encodeWireMsg (OpMsg op)) |> Bytes.width) |> List.sum
    in
    ( { model | lastSentOpBytes = totalBytes }, Cmd.batch (List.map (Crdt.Sync.send codec) ops) )


{-| Turns a textarea's `onInput` old/new value pair into a minimal sequence
of `Crdt.RText` char ops: common prefix and suffix are left alone, the
differing middle becomes delete-old-middle then insert-new-middle. Handles
ordinary typing, backspacing, pasting, and select-and-replace (all single
contiguous edit regions); doesn't attempt to reconstruct multi-cursor-style
edits as anything smarter than one big replace.
-}
applyTextDiff : String -> String -> RText.RText -> ( RText.RText, List RText.Op )
applyTextDiff oldStr newStr rtext =
    let
        oldChars =
            String.toList oldStr

        newChars =
            String.toList newStr

        prefixLen =
            commonPrefixLength oldChars newChars

        oldTail =
            List.drop prefixLen oldChars

        newTail =
            List.drop prefixLen newChars

        suffixLen =
            commonPrefixLength (List.reverse oldTail) (List.reverse newTail)
                |> min (List.length oldTail)
                |> min (List.length newTail)

        deleteCount =
            List.length oldChars - prefixLen - suffixLen

        insertedChars =
            newChars |> List.drop prefixLen |> List.take (List.length newChars - prefixLen - suffixLen)

        ( afterDeletes, deleteOps ) =
            List.foldl
                (\_ ( acc, ops ) ->
                    case RText.removeChar prefixLen acc of
                        Just ( newAcc, op ) ->
                            ( newAcc, op :: ops )

                        Nothing ->
                            ( acc, ops )
                )
                ( rtext, [] )
                (List.range 1 deleteCount)

        ( afterInserts, _, insertOps ) =
            List.foldl
                (\char ( acc, offset, ops ) ->
                    let
                        ( newAcc, op ) =
                            RText.insertChar (prefixLen + offset) char acc
                    in
                    ( newAcc, offset + 1, op :: ops )
                )
                ( afterDeletes, 0, [] )
                insertedChars
    in
    ( afterInserts, List.reverse deleteOps ++ List.reverse insertOps )


commonPrefixLength : List Char -> List Char -> Int
commonPrefixLength a b =
    case ( a, b ) of
        ( x :: xs, y :: ys ) ->
            if x == y then
                1 + commonPrefixLength xs ys

            else
                0

        _ ->
            0


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- VIEW


view : Model -> Browser.Document Msg
view model =
    { title = "Multi-Tab Demo – " ++ tabLabel model.tab
    , body =
        [ nav
        , case model.tab of
            Overview ->
                viewOverview

            Settings ->
                viewSettings

            Reports ->
                viewReports
        , viewTeamFeed model
        , viewStats model
        ]
    }


nav : Html msg
nav =
    ul []
        [ li [] [ a [ href "#" ] [ text "Overview" ] ]
        , li [] [ a [ href "#settings" ] [ text "Settings" ] ]
        , li [] [ a [ href "#reports" ] [ text "Reports" ] ]
        ]


viewOverview : Html msg
viewOverview =
    div []
        [ h1 [] [ text "Overview" ]
        , p [] [ text "Open this page with #settings or #reports in a new tab for a different UI." ]
        , viewFugueInterleavingTest
        ]


{-| Directly demonstrates the property Fugue is chosen for over plain RGA:
two sites concurrently type multi-character runs at the exact same
position, having never seen each other's edit. Pure computation (no ports,
no cross-tab sync needed) so it's independently verifiable on every page
load -- if `Crdt.List`'s tree-linking logic were wrong, this would show an
interleaved result like "XHWeolrllod" instead of the two words staying
intact as contiguous blocks.
-}
viewFugueInterleavingTest : Html msg
viewFugueInterleavingTest =
    let
        base =
            RText.init "seed"
                |> RText.insertChar 0 'X'
                |> Tuple.first

        siteA =
            RText.withSite "siteA" base

        siteB =
            RText.withSite "siteB" base

        ( afterA, _ ) =
            RText.insertString 1 "Hello" siteA

        ( afterB, _ ) =
            RText.insertString 1 "World" siteB

        merged =
            RText.sync afterA afterB

        result =
            RText.toString merged

        noInterleaving =
            String.contains "Hello" result && String.contains "World" result
    in
    div []
        [ h2 [] [ text "Fugue anti-interleaving self-check" ]
        , p []
            [ text "Site A and Site B both branch from \"X\" and concurrently type right after it, never seeing each other: A types \"Hello\", B types \"World\". After merging, each run must stay a contiguous block (either order), not interleave character-by-character." ]
        , pre [] [ code [] [ text ("merged: " ++ result) ] ]
        , p []
            [ text
                (if noInterleaving then
                    "OK: both words appear intact, unbroken by the other site's characters."

                 else
                    "FAIL: words are interleaved -- Fugue tree-linking has a bug."
                )
            ]
        ]


viewSettings : Html msg
viewSettings =
    div [] [ h1 [] [ text "Settings" ], p [] [ text "A different UI structure, e.g. a form." ] ]


viewReports : Html msg
viewReports =
    div [] [ h1 [] [ text "Reports" ], p [] [ text "Yet another UI, e.g. a table." ] ]


viewTeamFeed : Model -> Html Msg
viewTeamFeed model =
    div []
        [ h1 [] [ text "Team-Feed (Cross-Tab, CRDT-synced)" ]
        , div []
            [ button [ onClick Decrement ] [ text "-" ]
            , text (" " ++ String.fromInt (Counter.value model.shared.total) ++ " ")
            , button [ onClick Increment ] [ text "+" ]
            ]
        , div []
            [ input [ placeholder "Title, visible to all tabs...", value (LWW.value model.shared.title), onInput TitleChanged ] []
            ]
        , div []
            [ input [ placeholder "New tag...", value model.draftTag, onInput DraftTagChanged ] []
            , button [ onClick AddTag ] [ text "Add tag" ]
            ]
        , ul [] (List.map viewTag (CrdtDict.keys model.shared.tags))
        , div []
            [ textarea
                [ placeholder "Shared notes, live-collaborative (Crdt.RText / Fugue)..."
                , value (RText.toString model.shared.notes)
                , onInput NotesChanged
                ]
                []
            ]
        ]


viewTag : String -> Html Msg
viewTag tag =
    li [] [ text tag, button [ onClick (RemoveTag tag) ] [ text "x" ] ]


{-| Structural sizes (not just visible content) and the encoded size of the
last op this tab sent -- makes tombstone accumulation and message cost
observable instead of hidden. Also check the browser console: `crdt-
runtime.js` logs every message crossing the BroadcastChannel with its size.
-}
viewStats : Model -> Html msg
viewStats model =
    let
        shared =
            model.shared

        stateBytes =
            BE.encode (codec.encodeWireMsg (FullState shared)) |> Bytes.width
    in
    div []
        [ h2 [] [ text "Debug-Statistik" ]
        , ul []
            [ li [] [ text ("Counter: " ++ String.fromInt (Counter.siteCount shared.total) ++ " Site-Buckets (unabhängig von der Klickzahl)") ]
            , li []
                [ text
                    ("Tags: "
                        ++ String.fromInt (CrdtDict.size shared.tags)
                        ++ " sichtbar / "
                        ++ String.fromInt (CrdtDict.historySize shared.tags)
                        ++ " Tags insgesamt in der Historie (inkl. Tombstones)"
                    )
                ]
            , li []
                [ text
                    ("Notiz: "
                        ++ String.fromInt (RText.length shared.notes)
                        ++ " sichtbare Zeichen / "
                        ++ String.fromInt (RText.nodeCount shared.notes)
                        ++ " Knoten insgesamt (inkl. Tombstones)"
                    )
                ]
            , li [] [ text ("Gesamter Zustand codiert: " ++ formatBytes stateBytes ++ " (Bootstrap-Nachrichtengröße, inkl. WireMsg-Rahmen)") ]
            , li [] [ text ("Zuletzt gesendete Operation: " ++ formatBytes model.lastSentOpBytes) ]
            ]
        ]


formatBytes : Int -> String
formatBytes bytes =
    String.fromInt bytes ++ " B (" ++ String.fromFloat (toFloat (round (toFloat bytes / 1024 * 100)) / 100) ++ " KB)"


tabLabel : Tab -> String
tabLabel tab =
    case tab of
        Overview ->
            "Overview"

        Settings ->
            "Settings"

        Reports ->
            "Reports"



-- MAIN


main : Program String Model (Crdt.Sync.SyncMsg Msg)
main =
    Crdt.Sync.application
        codec
        { get = .shared, set = \v m -> { m | shared = v } }
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlChange = UrlChanged
        , onUrlRequest = LinkClicked
        }
