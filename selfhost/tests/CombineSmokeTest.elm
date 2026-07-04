module CombineSmokeTest exposing (suite)

import Combine exposing (Problem(..), parse, string)
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Combine smoke"
        [ test "string success" <|
            \_ ->
                case parse (string "hello") "hello world" of
                    Ok ( _, _, value ) ->
                        Expect.equal "hello" value

                    Err _ ->
                        Expect.fail "expected success"
        , test "string failure" <|
            \_ ->
                case parse (string "hello") "goodbye" of
                    Ok _ ->
                        Expect.fail "expected failure"

                    Err ( _, _, deadEnds ) ->
                        Expect.equal [ Expecting "\"hello\"" ] (List.map .problem deadEnds)
        ]
