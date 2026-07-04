module LabelTests exposing (suite)

import Combine exposing (Problem(..), expecting, keep, or, parse, string)
import Expect
import Test exposing (Test, describe, test)


problems result =
    case result of
        Err ( _, _, deadEnds ) ->
            List.map (\d -> ( d.row, d.col, d.problem )) deadEnds

        Ok _ ->
            []


suite : Test
suite =
    describe "expecting labels"
        [ test "uncommitted failure gets the label at entry position" <|
            \_ ->
                parse (string "ab\n" |> keep (expecting "a boolean" (or (string "true") (string "false")))) "ab\nnope"
                    |> problems
                    |> Expect.equal [ ( 2, 1, Expecting "a boolean" ) ]
        , test "committed failure keeps precise inner dead ends" <|
            \_ ->
                parse (expecting "a pair" (string "(" |> keep (string "1"))) "(x"
                    |> problems
                    |> Expect.equal [ ( 1, 2, Expecting "\"1\"" ) ]
        ]
