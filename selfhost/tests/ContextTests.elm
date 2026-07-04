module ContextTests exposing (suite)

import Combine exposing (Problem(..), ignore, inContext, keep, parse, string)
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "context stacks"
        [ test "dead end carries nested contexts, innermost first" <|
            \_ ->
                let
                    field =
                        inContext "record field" (string "x" |> keep (string "="))

                    record =
                        inContext "record" (string "{" |> keep field)
                in
                case parse record "{x:" of
                    Err ( _, _, [ d ] ) ->
                        Expect.equal
                            [ ( "record field", 1, 2 ), ( "record", 1, 1 ) ]
                            (List.map (\f -> ( f.context, f.row, f.col )) d.contextStack)

                    _ ->
                        Expect.fail "expected exactly one dead end"
        , test "contexts do not leak after the parser returns" <|
            \_ ->
                case parse (inContext "first" (string "a") |> keep (string "zz")) "ab" of
                    Err ( _, _, [ d ] ) ->
                        Expect.equal [] d.contextStack

                    _ ->
                        Expect.fail "expected exactly one dead end"
        ]
