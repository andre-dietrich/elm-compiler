module Combine.Num exposing (sign, digit, int, float)

{-| This module contains Parsers specific to parsing numbers.


# Parsers

@docs sign, digit, int, float

-}

import Char
import Combine exposing (Parser, andThen, fail, map, onerror, onsuccess, optional, or, regex, string, succeed)
import Combine.Char
import String


{-| Parse a numeric sign, returning `1` for positive numbers and `-1`
for negative numbers.

    parse sign "+" == Ok 1

    parse sign "-" == Ok -1

    parse sign "a" == Ok 1 -- optional: no sign means positive

-}
sign : Parser s Int
sign =
    optional 1
        (or
            (string "+" |> onsuccess 1)
            (string "-" |> onsuccess -1)
        )


{-| Parse a digit.

    parse digit "1" == Ok 1

    parse digit "a" == Err [ { row = 1, col = 1, problem = Expecting "a digit", contextStack = [] } ]

-}
digit : Parser s Int
digit =
    Combine.Char.digit
        -- 48 is the ASCII code for '0'
        |> map (\c -> Char.toCode c - 48)
        |> onerror "expected a digit"


{-| Parse an integer.

    parse int "123" == Ok 123

    parse int "-123" == Ok -123

    parse int "abc" == Err [ { row = 1, col = 1, problem = Expecting "an int", contextStack = [] } ]

-}
int : Parser s Int
int =
    regex "-?(?:0|[1-9]\\d*)"
        |> andThen (String.toInt >> unwrap)
        |> onerror "expected an int"


{-| Parse a float.

    parse float "123.456" == Ok 123.456

    parse float "-123.456" == Ok -123.456

    parse float "abc" == Err [ { row = 1, col = 1, problem = Expecting "a float", contextStack = [] } ]

-}
float : Parser s Float
float =
    regex "-?(?:0|[1-9]\\d*)\\.\\d+"
        |> andThen (String.toFloat >> unwrap)
        |> onerror "expected a float"


unwrap : Maybe v -> Parser s v
unwrap value =
    case value of
        Just v ->
            succeed v

        Nothing ->
            fail "impossible state in Combine.Num.unwrap"
