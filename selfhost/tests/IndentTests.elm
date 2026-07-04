module IndentTests exposing (suite)

import Combine exposing (Parser, andThen, fail, indentation, keep, parse, string, succeed, withColumn, withIndent)
import Expect
import Test exposing (Test, describe, test)


{-| Succeeds only if the current column is strictly greater than the
current indentation floor — the shape of Elm layout checks in M2.
-}
indented : Parser () ()
indented =
    indentation
        |> andThen
            (\floor_ ->
                withColumn
                    (\c ->
                        if c > floor_ then
                            succeed ()

                        else
                            fail "not indented"
                    )
            )


suite : Test
suite =
    describe "indentation state"
        [ test "default indentation is 0" <|
            \_ ->
                case parse indentation "" of
                    Ok ( _, _, i ) ->
                        Expect.equal 0 i

                    Err _ ->
                        Expect.fail "expected success"
        , test "withIndent sets and restores" <|
            \_ ->
                case
                    parse
                        (withIndent 4 indentation
                            |> andThen (\inner -> indentation |> Combine.map (\outer -> ( inner, outer )))
                        )
                        ""
                of
                    Ok ( _, _, pair ) ->
                        Expect.equal ( 4, 0 ) pair

                    Err _ ->
                        Expect.fail "expected success"
        , test "indented check passes past the floor" <|
            \_ ->
                case parse (string "ab\n   " |> keep (withIndent 2 indented)) "ab\n   x" of
                    Ok _ ->
                        Expect.pass

                    Err _ ->
                        Expect.fail "col 4 > floor 2 should pass"
        , test "indented check fails at the floor" <|
            \_ ->
                case parse (string "ab\n " |> keep (withIndent 2 indented)) "ab\n x" of
                    Ok _ ->
                        Expect.fail "col 2 is not past floor 2"

                    Err _ ->
                        Expect.pass
        ]
