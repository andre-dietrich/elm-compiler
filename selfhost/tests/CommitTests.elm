module CommitTests exposing (suite)

import Combine exposing (Problem(..), backtrackable, choice, ignore, keep, many, or, parse, string)
import Expect
import Test exposing (Test, describe, test)


problems result =
    case result of
        Err ( _, _, deadEnds ) ->
            List.map .problem deadEnds

        Ok _ ->
            []


suite : Test
suite =
    describe "committed choice"
        [ test "uncommitted failure tries next alternative" <|
            \_ ->
                case parse (or (string "aa") (string "ab")) "ab" of
                    Ok ( _, _, v ) ->
                        Expect.equal "ab" v

                    Err _ ->
                        Expect.fail "expected 'ab' branch to win"
        , test "committed failure stops alternation" <|
            \_ ->
                -- first branch consumes "a" then fails on "x"; second branch must NOT run
                parse
                    (or
                        (string "a" |> keep (string "x"))
                        (string "ab")
                    )
                    "ab"
                    |> problems
                    |> Expect.equal [ Expecting "\"x\"" ]
        , test "backtrackable undoes the commit" <|
            \_ ->
                case
                    parse
                        (or
                            (backtrackable (string "a" |> keep (string "x")))
                            (string "ab")
                        )
                        "ab"
                of
                    Ok ( _, _, v ) ->
                        Expect.equal "ab" v

                    Err _ ->
                        Expect.fail "expected backtracking to allow branch 2"
        , test "uncommitted failure merges dead ends from both branches" <|
            \_ ->
                parse (or (string "aa") (string "bb")) "cc"
                    |> problems
                    |> Expect.equal [ Expecting "\"aa\"", Expecting "\"bb\"" ]
        , test "many stops on uncommitted failure" <|
            \_ ->
                case parse (many (string "a")) "aab" of
                    Ok ( _, _, v ) ->
                        Expect.equal [ "a", "a" ] v

                    Err _ ->
                        Expect.fail "expected success"
        , test "many propagates committed failure" <|
            \_ ->
                -- element = "a" then "b"; third element consumes "a" then dies
                parse (many (string "a" |> keep (string "b"))) "ababac"
                    |> problems
                    |> Expect.equal [ Expecting "\"b\"" ]
        , test "choice respects commitment" <|
            \_ ->
                parse
                    (choice
                        [ string "a" |> keep (string "1")
                        , string "a" |> keep (string "2")
                        ]
                    )
                    "a2"
                    |> problems
                    |> Expect.equal [ Expecting "\"1\"" ]
        ]
