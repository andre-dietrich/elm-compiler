{-# LANGUAGE OverloadedStrings #-}
module Reporting.Error.Worker
  ( Error(..)
  , InvalidPayload(..)
  , toReport
  )
  where


import qualified Data.Name as Name

import qualified AST.Canonical as Can
import qualified Reporting.Annotation as A
import qualified Reporting.Doc as D
import qualified Reporting.Render.Code as Code
import qualified Reporting.Report as Report



-- ERROR


data Error
  = NotATopLevelFunction A.Region
  | UnappliedRun A.Region
  | InCyclicGroup A.Region Name.Name
  | BadPayload A.Region Can.Type InvalidPayload


-- Deliberately its own type, not a reuse of Reporting.Error.Canonicalize's
-- InvalidPayload -- Worker.run's safe-type whitelist is now much larger than
-- ports' (see Nitpick.Worker's checkClonable), so sharing the type would
-- either force ports to grow the same cases or force this module to pretend
-- cases it never produces (UnsupportedType) still apply. OpaqueType covers
-- both "this type's constructors are genuinely hidden" (a ClosedUnion/
-- PrivateUnion, e.g. Html.Html) and "this type's constructors aren't visible
-- from here" (defined in a module reachable only transitively, not directly
-- imported by the module calling Worker.run -- see Nitpick.Worker's
-- resolveUnion) -- both boil down to the same fact for the caller: I cannot
-- prove this type is safe to clone across a worker boundary.
data InvalidPayload
  = ExtendedRecord
  | Function
  | TypeVariable Name.Name
  | OpaqueType Name.Name



-- TO REPORT


toReport :: Code.Source -> Error -> Report.Report
toReport source err =
  case err of
    NotATopLevelFunction region ->
      Report.Report "BAD WORKER CALL" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "The first argument to `Worker.run` must be a plain reference to a\
              \ top-level function."
          ,
            D.reflow $
              "It cannot be an anonymous function, a partially applied function, or\
              \ anything that captures local values. Define it as its own top-level\
              \ function and pass that by name instead."
          )

    UnappliedRun region ->
      Report.Report "BAD WORKER CALL" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "`Worker.run` must be applied directly to the function you want to run\
              \ in a worker."
          ,
            D.reflow $
              "It cannot be passed around as a plain value or stored in a variable\
              \ without its function argument."
          )

    InCyclicGroup region name ->
      Report.Report "BAD WORKER CALL" region [] $
        Code.toSnippet source region Nothing
          (
            D.reflow $
              "The function `" <> Name.toChars name <> "` is part of a group of\
              \ functions that call each other recursively."
          ,
            D.reflow $
              "`Worker.run` cannot target a function that is part of a mutually\
              \ recursive group yet. Pull it out into its own non-recursive\
              \ top-level function."
          )

    BadPayload region _badType invalidPayload ->
      let
        formatDetails (aBadKindOfThing, elaboration) =
          Report.Report "BAD WORKER CALL" region [] $
            Code.toSnippet source region Nothing
              (
                D.reflow $
                  "The function passed to `Worker.run` takes or returns " <> aBadKindOfThing <> ":"
              ,
                elaboration
              )
      in
      formatDetails $
        case invalidPayload of
          ExtendedRecord ->
            (
              "an extended record"
            ,
              D.reflow $
                "But the exact shape of the record must be known at compile time.\
                \ No type variables!"
            )

          Function ->
            (
              "a function"
            ,
              D.reflow $
                "But functions cannot be sent to or from a worker. A worker runs in a\
                \ separate JS context, so only plain data can cross that boundary."
            )

          TypeVariable name ->
            (
              "an unspecified type"
            ,
              D.reflow $
                "But type variables like `" <> Name.toChars name <> "` cannot flow to\
                \ or from a worker. I need to know exactly what type of data is\
                \ crossing that boundary."
            )

          OpaqueType name ->
            (
              "a `" <> Name.toChars name <> "` value"
            ,
              D.stack
                [ D.reflow $
                    "I cannot verify that `" <> Name.toChars name <> "` is safe to send\
                    \ to a worker: its constructors are not visible here, either because\
                    \ the type deliberately hides them (like `Html.Html`) or because it is\
                    \ defined in a module this one does not import directly."
                , D.reflow $
                    "Almost any other type CAN cross a worker boundary: Ints, Floats, Bools,\
                    \ Chars, Strings, Maybes, Results, Lists, Arrays, Dicts, Sets, tuples,\
                    \ records, JSON values, and your own custom types (including recursive\
                    \ ones) -- as long as none of them contain a function."
                ]
            )
