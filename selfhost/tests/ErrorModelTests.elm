module ErrorModelTests exposing (suite)

import Combine exposing (Problem(..), andThen, end, fail, keep, parse, string, succeed)
import Expect
import Test exposing (Test, describe, test)


firstDeadEnd result =
    case result of
        Err ( _, _, d :: _ ) ->
            Just d

        _ ->
            Nothing


suite : Test
suite =
    describe "structured errors"
        [ test "string failure is Expecting at 1:1" <|
            \_ ->
                case firstDeadEnd (parse (string "hello") "goodbye") of
                    Just d ->
                        Expect.equal ( 1, 1, Expecting "\"hello\"" ) ( d.row, d.col, d.problem )

                    Nothing ->
                        Expect.fail "expected a dead end"
        , test "failure after consumption reports inner position" <|
            \_ ->
                case firstDeadEnd (parse (string "ab\nc" |> keep (string "xyz")) "ab\ncde") of
                    Just d ->
                        Expect.equal ( 2, 2, Expecting "\"xyz\"" ) ( d.row, d.col, d.problem )

                    Nothing ->
                        Expect.fail "expected a dead end"
        , test "end produces ExpectingEnd" <|
            \_ ->
                case firstDeadEnd (parse end "leftover") of
                    Just d ->
                        Expect.equal ExpectingEnd d.problem

                    Nothing ->
                        Expect.fail "expected a dead end"
        , test "fail produces Custom" <|
            \_ ->
                case firstDeadEnd (parse (fail "boom") "x") of
                    Just d ->
                        Expect.equal (Custom "boom") d.problem

                    Nothing ->
                        Expect.fail "expected a dead end"
        ]
