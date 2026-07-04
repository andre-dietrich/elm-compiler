module PositionTests exposing (suite)

import Combine exposing (ParseLocation, Parser, keep, parse, regex, string, succeed, withLocation)
import Expect
import Test exposing (Test, describe, test)


grabLocation : Parser () ParseLocation
grabLocation =
    withLocation succeed


locationAfter : Combine.Parser () a -> String -> Result String ( Int, Int )
locationAfter p input =
    case parse (p |> keep grabLocation) input of
        Ok ( _, _, loc ) ->
            Ok ( loc.line, loc.column )

        Err _ ->
            Err "parse failed"


suite : Test
suite =
    describe "incremental positions (1-based)"
        [ test "start position is 1:1" <|
            \_ -> Expect.equal (Ok ( 1, 1 )) (locationAfter (succeed ()) "abc")
        , test "single-line consumption advances col" <|
            \_ -> Expect.equal (Ok ( 1, 4 )) (locationAfter (string "abc") "abcdef")
        , test "newline resets col and bumps row" <|
            \_ -> Expect.equal (Ok ( 2, 3 )) (locationAfter (string "ab\ncd") "ab\ncdef")
        , test "regex consumption across lines" <|
            \_ -> Expect.equal (Ok ( 3, 1 )) (locationAfter (regex "[a-z]*\\n[a-z]*\\n") "ab\ncd\nef")
        , test "source line is extracted for current row" <|
            \_ ->
                case parse (string "ab\nc" |> keep grabLocation) "ab\ncde" of
                    Ok ( _, _, loc ) ->
                        Expect.equal "cde" loc.source

                    Err _ ->
                        Expect.fail "parse failed"
        ]
