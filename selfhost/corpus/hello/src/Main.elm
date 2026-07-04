port module Main exposing (main)

import Platform


port emit : String -> Cmd msg


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), emit "hello, corpus" )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
