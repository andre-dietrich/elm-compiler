port module Crdt.Sync exposing (SyncMsg, send, application)

{-| Wraps `Browser.application` so the wrapped app's `update`/`view`/
`subscriptions` never see ports, encoding, or merge logic directly.
Receiving is fully automatic; sending only needs the app to hand the small
`SharedOp` it just produced to `send` (see `Shared.elm` for why a setter is
unavoidable at the Model<->SharedState boundary, but nowhere else).

Three wire message kinds share the same two ports:
  - `OpMsg`: an incremental change (small).
  - `RequestState`: sent once on startup so a newly opened tab can catch up.
  - `FullState`: the answer to `RequestState` (or the demo's only large message).
-}

import Browser
import Browser.Navigation as Nav
import Html
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Shared exposing (SharedOp, SharedState)
import Url exposing (Url)


port crdtSend : Encode.Value -> Cmd msg


port crdtReceive : (Decode.Value -> msg) -> Sub msg


send : SharedOp -> Cmd msg
send op =
    crdtSend (encodeWireMsg (OpMsg op))


type WireMsg
    = OpMsg SharedOp
    | RequestState
    | FullState SharedState


encodeWireMsg : WireMsg -> Encode.Value
encodeWireMsg msg =
    case msg of
        OpMsg op ->
            Encode.object [ ( "kind", Encode.string "op" ), ( "payload", Shared.encodeOp op ) ]

        RequestState ->
            Encode.object [ ( "kind", Encode.string "requestState" ) ]

        FullState state ->
            Encode.object [ ( "kind", Encode.string "fullState" ), ( "payload", Shared.encode state ) ]


wireMsgDecoder : Decoder WireMsg
wireMsgDecoder =
    Decode.field "kind" Decode.string
        |> Decode.andThen
            (\kind ->
                case kind of
                    "op" ->
                        Decode.map OpMsg (Decode.field "payload" Shared.opDecoder)

                    "requestState" ->
                        Decode.succeed RequestState

                    "fullState" ->
                        Decode.map FullState (Decode.field "payload" Shared.decoder)

                    _ ->
                        Decode.fail ("unknown WireMsg kind: " ++ kind)
            )


type SyncMsg msg
    = AppMsg msg
    | GotWire Decode.Value


application :
    { get : model -> SharedState, set : SharedState -> model -> model }
    ->
        { init : flags -> Url -> Nav.Key -> ( model, Cmd msg )
        , view : model -> Browser.Document msg
        , update : msg -> model -> ( model, Cmd msg )
        , subscriptions : model -> Sub msg
        , onUrlChange : Url -> msg
        , onUrlRequest : Browser.UrlRequest -> msg
        }
    -> Program flags model (SyncMsg msg)
application c app =
    Browser.application
        { init =
            \flags url key ->
                let
                    ( model, cmd ) =
                        app.init flags url key
                in
                ( model, Cmd.batch [ Cmd.map AppMsg cmd, crdtSend (encodeWireMsg RequestState) ] )
        , view =
            \model ->
                let
                    doc =
                        app.view model
                in
                { title = doc.title, body = List.map (Html.map AppMsg) doc.body }
        , update =
            \msg model ->
                case msg of
                    AppMsg inner ->
                        app.update inner model |> Tuple.mapSecond (Cmd.map AppMsg)

                    GotWire value ->
                        case Decode.decodeValue wireMsgDecoder value of
                            Ok (OpMsg op) ->
                                ( c.set (Shared.applyOp op (c.get model)) model, Cmd.none )

                            Ok RequestState ->
                                ( model, crdtSend (encodeWireMsg (FullState (c.get model))) )

                            Ok (FullState remote) ->
                                ( c.set (Shared.sync (c.get model) remote) model, Cmd.none )

                            Err _ ->
                                ( model, Cmd.none )
        , subscriptions =
            \model -> Sub.batch [ Sub.map AppMsg (app.subscriptions model), crdtReceive GotWire ]
        , onUrlChange = \url -> AppMsg (app.onUrlChange url)
        , onUrlRequest = \req -> AppMsg (app.onUrlRequest req)
        }
