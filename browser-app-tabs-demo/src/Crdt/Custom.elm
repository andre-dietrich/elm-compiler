module Crdt.Custom exposing (Custom, Op, init, value, set, applyOp, merge)

{-| Escape hatch for CRDT merge policies that a fixed LWW tie-break is too
coarse for -- e.g. a union type where a state-machine rule ("Archived always
wins") should decide the outcome instead of whichever write happened to be
newest. The caller supplies a `combine` function that must be commutative,
idempotent, and associative; that contract is documented, not enforced by
the type system (the same trust model Elm already uses for e.g. custom
`Json.Decode` decoders).
-}


type Custom a
    = Custom a


type alias Op a =
    a


init : a -> Custom a
init v =
    Custom v


value : Custom a -> a
value (Custom v) =
    v


set : a -> Custom a -> ( Custom a, Op a )
set newValue _ =
    ( Custom newValue, newValue )


applyOp : (a -> a -> a) -> Op a -> Custom a -> Custom a
applyOp combine op (Custom current) =
    Custom (combine current op)


merge : (a -> a -> a) -> Custom a -> Custom a -> Custom a
merge combine (Custom a) (Custom b) =
    Custom (combine a b)
