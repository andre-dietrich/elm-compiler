module CombineSmokeTest exposing (suite)

import Combine exposing (parse, string)
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Combine smoke (7.0.2 API)"
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

                    Err ( _, _, messages ) ->
                        Expect.equal [ "expected \"hello\"" ] messages
        ]
