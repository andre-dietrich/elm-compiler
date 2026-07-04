module MiniGrammarTests exposing (suite)

import Combine
    exposing
        ( Parser
        , andThen
        , expecting
        , fail
        , ignore
        , inContext
        , keep
        , many
        , many1
        , parse
        , regex
        , string
        , succeed
        , withColumn
        , withIndent
        , withLocation
        )
import Combine.Num
import Expect
import Test exposing (Test, describe, test)


type alias Binding =
    ( String, Int )


spaces : Parser () String
spaces =
    regex "[ \\n]*"


indented : Parser () ()
indented =
    Combine.indentation
        |> andThen
            (\floor_ ->
                withColumn
                    (\c ->
                        if c > floor_ then
                            succeed ()

                        else
                            fail "binding must be indented past 'let'"
                    )
            )


binding : Parser () Binding
binding =
    inContext "binding" <|
        (indented
            |> keep (expecting "a name" (regex "[a-z]+"))
            |> ignore spaces
            |> ignore (string "=")
            |> ignore spaces
            |> andThen (\name -> Combine.Num.int |> Combine.map (\n -> ( name, n )))
        )


letBlock : Parser () (List Binding)
letBlock =
    inContext "let block" <|
        (withLocation
            (\loc ->
                string "let"
                    |> keep
                        (withIndent loc.column
                            (many1 (spaces |> keep (Combine.backtrackable binding)))
                        )
            )
        )


suite : Test
suite =
    describe "mini indentation-sensitive grammar"
        [ test "parses indented bindings" <|
            \_ ->
                case parse letBlock "let\n  x = 1\n  y = 2" of
                    Ok ( _, _, bindings ) ->
                        Expect.equal [ ( "x", 1 ), ( "y", 2 ) ] bindings

                    Err ( _, _, deadEnds ) ->
                        Expect.fail (Combine.deadEndsToString deadEnds)
        , test "rejects binding at the let column" <|
            \_ ->
                case parse letBlock "let\nx = 1" of
                    Ok _ ->
                        Expect.fail "should reject non-indented binding"

                    Err _ ->
                        Expect.pass
        , test "error inside a binding carries both contexts" <|
            \_ ->
                case parse letBlock "let\n  x =" of
                    Err ( _, _, deadEnds ) ->
                        case List.head deadEnds of
                            Just d ->
                                d.contextStack
                                    |> List.map .context
                                    |> Expect.equal [ "binding", "let block" ]

                            Nothing ->
                                Expect.fail "expected a dead end"

                    Ok _ ->
                        Expect.fail "expected failure"
        ]
