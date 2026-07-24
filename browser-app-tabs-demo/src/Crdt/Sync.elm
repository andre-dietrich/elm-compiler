port module Crdt.Sync exposing (SyncMsg, Codec, WireMsg(..), send, application)

{-| Wraps `Browser.application` so the wrapped app's `update`/`view`/
`subscriptions` never see ports, encoding, or merge logic directly.
Receiving is fully automatic; sending only needs the app to hand the small
`SharedOp` it just produced to `send` (see `Shared.elm` for why a setter is
unavoidable at the Model<->SharedState boundary, but nowhere else).

Three wire message kinds share the same two ports:
  - `OpMsg`: an incremental change (small).
  - `RequestState`: sent once on startup so a newly opened tab can catch up.
  - `FullState`: the answer to `RequestState` (or the demo's only large message).

`WireMsg` itself is format-agnostic; how it's turned into bytes is supplied
externally as a `Codec` (see `Shared.Json`/`Shared.Binary`), so switching
formats is a single argument at the `Main.elm` call site, not a structural
change here.
-}

import Browser
import Browser.Navigation as Nav
import Bytes exposing (Bytes)
import Bytes.Decode as BD
import Bytes.Encode as BE
import Crdt.Wire as Wire
import Html
import Shared exposing (SharedOp, SharedState)
import Url exposing (Url)


port crdtSend : String -> Cmd msg


port crdtReceive : (String -> msg) -> Sub msg


type WireMsg
    = OpMsg SharedOp
    | RequestState
    | FullState SharedState


type alias Codec =
    { encodeWireMsg : WireMsg -> BE.Encoder
    , wireMsgDecoder : BD.Decoder WireMsg
    }


send : Codec -> SharedOp -> Cmd msg
send codec op =
    crdtSend (encodeToPort codec (OpMsg op))


encodeToPort : Codec -> WireMsg -> String
encodeToPort codec msg =
    Wire.toPortString (BE.encode (codec.encodeWireMsg msg))


type SyncMsg msg
    = AppMsg msg
    | GotWire String


application :
    Codec
    -> { get : model -> SharedState, set : SharedState -> model -> model }
    ->
        { init : flags -> Url -> Nav.Key -> ( model, Cmd msg )
        , view : model -> Browser.Document msg
        , update : msg -> model -> ( model, Cmd msg )
        , subscriptions : model -> Sub msg
        , onUrlChange : Url -> msg
        , onUrlRequest : Browser.UrlRequest -> msg
        }
    -> Program flags model (SyncMsg msg)
application codec c app =
    Browser.application
        { init =
            \flags url key ->
                let
                    ( model, cmd ) =
                        app.init flags url key
                in
                ( model, Cmd.batch [ Cmd.map AppMsg cmd, crdtSend (encodeToPort codec RequestState) ] )
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

                    GotWire portStr ->
                        case BD.decode codec.wireMsgDecoder (Wire.fromPortString portStr) of
                            Just (OpMsg op) ->
                                ( c.set (Shared.applyOp op (c.get model)) model, Cmd.none )

                            Just RequestState ->
                                ( model, crdtSend (encodeToPort codec (FullState (c.get model))) )

                            Just (FullState remote) ->
                                ( c.set (Shared.sync (c.get model) remote) model, Cmd.none )

                            Nothing ->
                                ( model, Cmd.none )
        , subscriptions =
            \model -> Sub.batch [ Sub.map AppMsg (app.subscriptions model), crdtReceive GotWire ]
        , onUrlChange = \url -> AppMsg (app.onUrlChange url)
        , onUrlRequest = \req -> AppMsg (app.onUrlRequest req)
        }
