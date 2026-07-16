{-# OPTIONS_GHC -fno-warn-x-partial #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
module Generate.JavaScript.Expression
  ( generate
  , generateCtor
  , generateField
  , generateTailDef
  , generateTailDefCons
  , generateMain
  , generateUnwrapped
  , generateUnwrappedTail
  , Code
  , codeToExpr
  , codeToStmtList
  )
  where


import Data.ByteString.Builder.Prim ((>$<), (>*<))
import qualified Data.ByteString.Builder.Prim as P
import qualified Data.Char as Char
import qualified Data.IntMap as IntMap
import qualified Data.List as List
import Data.Map ((!))
import qualified Data.Map as Map
import qualified Data.Name as Name
import qualified Data.Set as Set
import qualified Data.Utf8 as Utf8

import qualified AST.Canonical as Can
import qualified AST.Optimized as Opt
import qualified AST.Utils.Shader as Shader
import qualified Data.Index as Index
import qualified Elm.Compiler.Type as Type
import qualified Elm.Compiler.Type.Extract as Extract
import qualified Elm.Version as V
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified Generate.JavaScript.Builder as JS
import qualified Generate.JavaScript.Name as JsName
import qualified Generate.Mode as Mode
import qualified Json.Encode as Encode
import Json.Encode ((==>))
import qualified Optimize.DecisionTree as DT
import qualified Reporting.Annotation as A



-- EXPRESSIONS


generateJsExpr :: Mode.Mode -> Opt.Expr -> JS.Expr
generateJsExpr mode expression =
  codeToExpr (generate mode expression)


generate :: Mode.Mode -> Opt.Expr -> Code
generate mode expression =
  case expression of
    Opt.Bool b -> JsExpr $ JS.Bool b
    Opt.Chr c ->
      JsExpr $
        case mode of
          Mode.Dev  _ -> JS.Call toChar [ JS.String (P.primBounded charUtf8 c) ]
          Mode.Prod _ _ -> JS.String (P.primBounded charUtf8 c)

    Opt.Str      s -> JsExpr $ JS.String (Utf8.toBuilder s)
    Opt.Int      i -> JsExpr $ JS.Int i
    Opt.Float    f -> JsExpr $ JS.Float (Utf8.toBuilder f)
    Opt.VarLocal x -> JsExpr $ JS.Ref (JsName.fromLocal x)

    Opt.VarGlobal (Opt.Global h n) ->
      JsExpr $ JS.Ref (JsName.fromGlobal h n)

    Opt.VarEnum (Opt.Global home name) index ->
      case mode of
        Mode.Dev  _ -> JsExpr $ JS.Ref (JsName.fromGlobal home name)
        Mode.Prod _ _ -> JsExpr $ JS.Int (Index.toMachine index)

    Opt.VarBox (Opt.Global home name) ->
      JsExpr $ JS.Ref $
        case mode of
          Mode.Dev  _ -> JsName.fromGlobal home name
          Mode.Prod _ _ -> JsName.fromGlobal ModuleName.basics Name.identity

    Opt.VarCycle h n     -> JsExpr $ JS.Call (JS.Ref (JsName.fromCycle h n)) []
    Opt.VarDebug n h r u -> JsExpr $ generateDebug n h r u
    Opt.VarKernel  h n   -> JsExpr $ JS.Ref (JsName.fromKernel h n)

    Opt.List entries ->
      JsExpr $
        List.foldr (\entry acc -> JS.Call listCons [generateJsExpr mode entry, acc]) listNil entries

    Opt.Function args body ->
      generateFunction (map JsName.fromLocal args) (generate mode body)

    Opt.Call f xs     -> JsExpr $ generateCall mode f xs
    Opt.TailCall n xs -> JsBlock $ generateTailCall mode n xs
    Opt.TailCallCons n headExpr xs -> JsBlock $ generateTailCallCons mode n headExpr xs
    Opt.TailCallConsBase n valueExpr -> JsBlock $ generateTailCallConsBase mode n valueExpr
    Opt.If bs f       -> generateIf mode bs f

    Opt.Let def body ->
      let mode' = extendWithLocalArity mode def in
      JsBlock $
        generateDef mode' def : codeToStmtList (generate mode' body)

    Opt.Destruct (Opt.Destructor name path) body ->
      let
        pathDef = JS.Var (JsName.fromLocal name) (generatePath mode path)
      in
      JsBlock $ pathDef : codeToStmtList (generate mode body)

    Opt.Case label root decider jumps ->
      JsBlock $ generateCase mode label root decider jumps

    Opt.Accessor field ->
      JsExpr $ JS.Function Nothing [JsName.dollar]
        [ JS.Return $
            JS.Access (JS.Ref JsName.dollar) (generateField mode field)
        ]

    Opt.Access record field ->
      JsExpr $ JS.Access (generateJsExpr mode record) (generateField mode field)

    Opt.Update record fields ->
      generateUpdate mode record fields

    Opt.Record fields ->
      JsExpr $ generateRecord mode fields

    Opt.Unit ->
      case mode of
        Mode.Dev  _ -> JsExpr $ JS.Ref (JsName.fromKernel Name.utils "Tuple0")
        Mode.Prod _ _ -> JsExpr $ JS.Int 0

    Opt.Tuple a b maybeC ->
      JsExpr $ generateTuple mode a b maybeC

    Opt.Shader src attributes uniforms ->
      let
        toTranlation field =
          ( JsName.fromLocal field
          , JS.String (JsName.toBuilder (generateField mode field))
          )

        toTranslationObject fields =
          JS.Object (map toTranlation (Set.toList fields))
      in
      JsExpr $ JS.Object $
        [ ( JsName.fromLocal "src", JS.String (Shader.toJsStringBuilder src) )
        , ( JsName.fromLocal "attributes", toTranslationObject attributes )
        , ( JsName.fromLocal "uniforms", toTranslationObject uniforms )
        ]

    Opt.PrimOp op left right ->
      JsExpr $ generatePrimOp mode op left right



-- CODE CHUNKS


data Code
  = JsExpr JS.Expr
  | JsBlock [JS.Stmt]


codeToExpr :: Code -> JS.Expr
codeToExpr code =
  case code of
    JsExpr             expr  -> expr
    JsBlock [JS.Return expr] -> expr
    JsBlock stmts            -> JS.Call (JS.Function Nothing [] stmts) []


codeToStmtList :: Code -> [JS.Stmt]
codeToStmtList code =
  case code of
    JsExpr (JS.Call (JS.Function Nothing [] stmts) []) ->
        stmts

    JsExpr expr ->
        [ JS.Return expr ]

    JsBlock stmts ->
        stmts


codeToStmt :: Code -> JS.Stmt
codeToStmt code =
  case code of
    JsExpr (JS.Call (JS.Function Nothing [] stmts) []) ->
        JS.Block stmts

    JsExpr expr ->
        JS.Return expr

    JsBlock [stmt] ->
        stmt

    JsBlock stmts ->
        JS.Block stmts



-- CHARS


{-# NOINLINE toChar #-}
toChar :: JS.Expr
toChar =
  JS.Ref (JsName.fromKernel Name.utils "chr")



-- CTOR


generateCtor :: Mode.Mode -> Opt.Global -> Index.ZeroBased -> Int -> Int -> Code
generateCtor mode (Opt.Global home name) index arity maxArity =
  let
    argNames =
      Index.indexedMap (\i _ -> JsName.fromIndex i) [1 .. arity]

    -- pad all variants of a union to the same object shape (monomorphic
    -- shapes let JS engines share hidden classes across variants)
    padNames =
      case mode of
        Mode.Dev  _ -> []
        Mode.Prod _ _ ->
          drop arity (Index.indexedMap (\i _ -> JsName.fromIndex i) [1 .. maxArity])

    ctorTag =
      case mode of
        Mode.Dev  _ -> JS.String (Name.toBuilder name)
        Mode.Prod _ _ -> JS.Int (ctorToInt home name index)
  in
  generateFunction argNames $ JsExpr $ JS.Object $
    (JsName.dollar, ctorTag)
      : map (\n -> (n, JS.Ref n)) argNames
     ++ map (\n -> (n, JS.Null)) padNames


ctorToInt :: ModuleName.Canonical -> Name.Name -> Index.ZeroBased -> Int
ctorToInt home name index =
  if home == ModuleName.dict && name == "RBNode_elm_builtin" || name == "RBEmpty_elm_builtin" then
    0 - Index.toHuman index
  else
    Index.toMachine index



-- TUPLES


generateTuple :: Mode.Mode -> Opt.Expr -> Opt.Expr -> Maybe Opt.Expr -> JS.Expr
generateTuple mode a b maybeC =
  let
    tag n =
      case mode of
        Mode.Dev  _   -> [ (JsName.dollar, JS.String n) ]
        Mode.Prod _ _ -> []
  in
  case maybeC of
    Nothing ->
      JS.Object $ tag "#2" ++
        [ (JsName.fromIndex Index.first,  generateJsExpr mode a)
        , (JsName.fromIndex Index.second, generateJsExpr mode b)
        ]

    Just c ->
      JS.Object $ tag "#3" ++
        [ (JsName.fromIndex Index.first,  generateJsExpr mode a)
        , (JsName.fromIndex Index.second, generateJsExpr mode b)
        , (JsName.fromIndex Index.third,  generateJsExpr mode c)
        ]



-- RECORDS


generateRecord :: Mode.Mode -> Map.Map Name.Name Opt.Expr -> JS.Expr
generateRecord mode fields =
  let
    toPair (field, value) =
      (generateField mode field, generateJsExpr mode value)
  in
  JS.Object (map toPair (Map.toList fields))


generateField :: Mode.Mode -> Name.Name -> JsName.Name
generateField mode name =
  case mode of
    Mode.Dev _       -> JsName.fromLocal name
    Mode.Prod fields _ -> fields ! name



-- RECORD UPDATES


generateUpdate :: Mode.Mode -> Opt.Expr -> Map.Map Name.Name Opt.Expr -> Code
generateUpdate mode record fields =
  case mode of
    Mode.Prod _ _ | hasNestedUpdate fields ->
      JsExpr $ generateInlineUpdate mode record fields

    _ ->
      JsExpr $ generateUpdateCall mode record fields


generateUpdateCall :: Mode.Mode -> Opt.Expr -> Map.Map Name.Name Opt.Expr -> JS.Expr
generateUpdateCall mode record fields =
  JS.Call (JS.Ref (JsName.fromKernel Name.utils "update"))
    [ generateJsExpr mode record
    , generateRecord mode fields
    ]


hasNestedUpdate :: Map.Map Name.Name Opt.Expr -> Bool
hasNestedUpdate =
  any isUpdate


isUpdate :: Opt.Expr -> Bool
isUpdate expr =
  case expr of
    Opt.Update _ _ -> True
    _              -> False


generateInlineUpdate :: Mode.Mode -> Opt.Expr -> Map.Map Name.Name Opt.Expr -> JS.Expr
generateInlineUpdate mode record fields =
  JS.Call
    (JS.Function Nothing [updateRecord] (generateInlineUpdateBody mode fields))
    [ generateJsExpr mode record ]


generateInlineUpdateBody :: Mode.Mode -> Map.Map Name.Name Opt.Expr -> [JS.Stmt]
generateInlineUpdateBody mode fields =
  [ JS.Var updateResult (JS.Object [])
  , JS.ForIn updateKey (JS.Ref updateRecord) $
      JS.ExprStmt $
        JS.Assign
          (JS.LBracket (JS.Ref updateResult) (JS.Ref updateKey))
          (JS.Index (JS.Ref updateRecord) (JS.Ref updateKey))
  ]
  ++ map (generateInlineUpdateField mode) (Map.toList fields)
  ++ [ JS.Return (JS.Ref updateResult) ]


generateInlineUpdateField :: Mode.Mode -> (Name.Name, Opt.Expr) -> JS.Stmt
generateInlineUpdateField mode (field, value) =
  JS.ExprStmt $
    JS.Assign
      (JS.LDot (JS.Ref updateResult) (generateField mode field))
      (generateInlineUpdateValue mode value)


generateInlineUpdateValue :: Mode.Mode -> Opt.Expr -> JS.Expr
generateInlineUpdateValue mode value =
  case value of
    Opt.Update record fields ->
      generateInlineUpdate mode record fields

    _ ->
      generateJsExpr mode value


updateRecord :: JsName.Name
updateRecord =
  JsName.fromLocal "$record"


updateResult :: JsName.Name
updateResult =
  JsName.fromLocal "$updated"


updateKey :: JsName.Name
updateKey =
  JsName.fromLocal "$key"




-- DEBUG


generateDebug :: Name.Name -> ModuleName.Canonical -> A.Region -> Maybe Name.Name -> JS.Expr
generateDebug name (ModuleName.Canonical _ home) region unhandledValueName =
  if name /= "todo" then
    JS.Ref (JsName.fromGlobal ModuleName.debug name)
  else
    case unhandledValueName of
      Nothing ->
        JS.Call (JS.Ref (JsName.fromKernel Name.debug "todo")) $
          [ JS.String (Name.toBuilder home)
          , regionToJsExpr region
          ]

      Just valueName ->
        JS.Call (JS.Ref (JsName.fromKernel Name.debug "todoCase")) $
          [ JS.String (Name.toBuilder home)
          , regionToJsExpr region
          , JS.Ref (JsName.fromLocal valueName)
          ]


regionToJsExpr :: A.Region -> JS.Expr
regionToJsExpr (A.Region start end) =
  JS.Object
    [ "start" ===> JS.Object [ "line" ===> JS.Int sr, "column" ===> JS.Int sc ]
    , "end"   ===> JS.Object [ "line" ===> JS.Int er, "column" ===> JS.Int ec ]
    ]
  where
    (===>) n v = (JsName.fromLocal n, v)
    (sr, sc) = A.toRowCol start
    (er, ec) = A.toRowCol end



-- FUNCTION


generateFunction :: [JsName.Name] -> Code -> Code
generateFunction args body =
  case IntMap.lookup (length args) funcHelpers of
    Just helper ->
      JsExpr $
        JS.Call helper
          [ JS.Function Nothing args $
              codeToStmtList body
          ]

    Nothing ->
      let
        addArg arg code =
          JsExpr $ JS.Function Nothing [arg] $
            codeToStmtList code
      in
      foldr addArg body args


{-# NOINLINE funcHelpers #-}
funcHelpers :: IntMap.IntMap JS.Expr
funcHelpers =
  IntMap.fromList $
    map (\n -> (n, JS.Ref (JsName.makeF n))) [2..9]



-- CALLS


generateCall :: Mode.Mode -> Opt.Expr -> [Opt.Expr] -> JS.Expr
generateCall mode func args =
  case func of
    Opt.VarGlobal global | Just unwrappedCall <- generateUnwrappedCall mode global args ->
      unwrappedCall

    -- inside an `$unwrapped` variant the callback parameter holds a raw
    -- JS function, so a saturated call of it must not go through A2..A9
    Opt.VarLocal x | Just (raw, arity) <- Mode.lookupRawLocal mode
                   , x == raw
                   , arity == length args ->
      JS.Call (JS.Ref (JsName.fromLocal x)) (map (generateJsExpr mode) args)

    -- a call to a local let-bound function whose arity is known from its
    -- own binding (see Opt.Let handling / extendWithLocalArity): skip
    -- A2..A9 and call its raw `.f` field directly, the same way
    -- generateDirectCall does for globals.
    Opt.VarLocal x | Just arity <- Mode.lookupLocalArity mode x, arity == length args ->
      generateDirectLocalCall mode x args

    Opt.VarGlobal global@(Opt.Global (ModuleName.Canonical pkg _) _) | pkg == Pkg.core ->
      generateCoreCall mode global args

    Opt.VarGlobal global | Just arity <- Mode.lookupArity mode global, arity == length args ->
      generateDirectCall mode global args

    Opt.VarBox _ ->
      case mode of
        Mode.Dev  _ -> generateCallHelp mode func args
        Mode.Prod _ _ ->
          case args of
            [arg] -> generateJsExpr mode arg
            _     -> generateCallHelp mode func args

    _ ->
      generateCallHelp mode func args


generateCallHelp :: Mode.Mode -> Opt.Expr -> [Opt.Expr] -> JS.Expr
generateCallHelp mode func args =
  generateNormalCall
    (generateJsExpr mode func)
    (map (generateJsExpr mode) args)


generateGlobalCall :: ModuleName.Canonical -> Name.Name -> [JS.Expr] -> JS.Expr
generateGlobalCall home name args =
  generateNormalCall (JS.Ref (JsName.fromGlobal home name)) args


-- A call site with exactly as many arguments as the callee's known arity
-- always takes the `fun.a === N` branch of `A2`..`A9` (see Generate.Mode).
-- Reading `fun.f` and calling it directly skips that check and keeps the
-- call site monomorphic instead of routing it through the shared,
-- megamorphic `A2`..`A9` helpers.
generateDirectCall :: Mode.Mode -> Opt.Global -> [Opt.Expr] -> JS.Expr
generateDirectCall mode (Opt.Global home name) args =
  JS.Call
    (JS.Access (JS.Ref (JsName.fromGlobal home name)) rawFunctionField)
    (map (generateJsExpr mode) args)


-- Same idea as generateDirectCall, but for a local let-bound function
-- instead of a global.
generateDirectLocalCall :: Mode.Mode -> Name.Name -> [Opt.Expr] -> JS.Expr
generateDirectLocalCall mode name args =
  JS.Call
    (JS.Access (JS.Ref (JsName.fromLocal name)) rawFunctionField)
    (map (generateJsExpr mode) args)


rawFunctionField :: JsName.Name
rawFunctionField =
  JsName.fromLocal "f"


-- UNWRAPPED HOF CALLS
--
-- A saturated call of a higher-order function that qualifies per
-- Mode.lookupUnwrapped, whose callback argument has statically known
-- arity, is redirected to the function's `$unwrapped` variant with the
-- callback passed as a raw JS function (no F2..F9 wrapper). Inside the
-- variant the callback is called directly, so per-element A2 dispatch
-- and the wrapper frame disappear.


generateUnwrappedCall :: Mode.Mode -> Opt.Global -> [Opt.Expr] -> Maybe JS.Expr
generateUnwrappedCall mode global@(Opt.Global home name) args =
  case Mode.lookupUnwrapped mode global of
    Just (index, arity) | Mode.lookupArity mode global == Just (length args) ->
      case generateRawCallback mode arity (args !! index) of
        Just rawCallback ->
          Just $ JS.Call (JS.Ref (JsName.fromGlobalUnwrapped home name)) $
            zipWith
              (\i arg -> if i == index then rawCallback else generateJsExpr mode arg)
              [ (0 :: Int) .. ]
              args

        Nothing ->
          Nothing

    _ ->
      Nothing


generateRawCallback :: Mode.Mode -> Int -> Opt.Expr -> Maybe JS.Expr
generateRawCallback mode arity expr =
  case expr of
    -- a function literal of matching arity: emit it without the wrapper
    Opt.Function params body | length params == arity ->
      Just $ JS.Function Nothing (map JsName.fromLocal params) $
        codeToStmtList (generate mode body)

    -- a reference to a top-level definition of matching arity: its `.f`
    -- field is the raw function behind the F2..F9 wrapper
    Opt.VarGlobal cb@(Opt.Global cbHome cbName) | Mode.lookupArity mode cb == Just arity ->
      Just $ JS.Access (JS.Ref (JsName.fromGlobal cbHome cbName)) rawFunctionField

    -- inside an `$unwrapped` variant: pass the raw callback right along
    Opt.VarLocal x | Mode.lookupRawLocal mode == Just (x, arity) ->
      Just $ JS.Ref (JsName.fromLocal x)

    _ ->
      Nothing


-- UNWRAPPED VARIANTS


generateUnwrapped :: Mode.Mode -> Opt.Global -> Opt.Expr -> Maybe JS.Stmt
generateUnwrapped mode global expr =
  case expr of
    Opt.Function params body -> generateUnwrappedHelp False mode global params body
    _ -> Nothing


generateUnwrappedTail :: Mode.Mode -> Opt.Global -> [Name.Name] -> Opt.Expr -> Maybe JS.Stmt
generateUnwrappedTail =
  generateUnwrappedHelp True


-- The `$unwrapped` sibling of a qualifying higher-order function: a plain
-- JS function (it is only ever called saturated, from call sites rewritten
-- by generateUnwrappedCall, so it needs no wrapper itself) whose callback
-- parameter is a raw JS function.
generateUnwrappedHelp :: Bool -> Mode.Mode -> Opt.Global -> [Name.Name] -> Opt.Expr -> Maybe JS.Stmt
generateUnwrappedHelp isTailFunc mode global@(Opt.Global home name) params body =
  case Mode.lookupUnwrapped mode global of
    Nothing ->
      Nothing

    Just (index, arity) ->
      let
        rawMode =
          Mode.setRawLocal (params !! index) arity mode

        bodyCode =
          if isTailFunc then
            JsBlock
              [ JS.Labelled (JsName.fromLocal name) $
                  JS.While (JS.Bool True) $
                    codeToStmt $ generate rawMode body
              ]
          else
            generate rawMode body
      in
      Just $ JS.Var (JsName.fromGlobalUnwrapped home name) $
        JS.Function Nothing (map JsName.fromLocal params) $
          codeToStmtList bodyCode


generateNormalCall :: JS.Expr -> [JS.Expr] -> JS.Expr
generateNormalCall func args =
  case IntMap.lookup (length args) callHelpers of
    Just helper -> JS.Call helper (func:args)
    Nothing     -> List.foldl' (\f a -> JS.Call f [a]) func args


{-# NOINLINE callHelpers #-}
callHelpers :: IntMap.IntMap JS.Expr
callHelpers =
  IntMap.fromList $
    map (\n -> (n, JS.Ref (JsName.makeA n))) [2..9]



-- CORE CALLS


generateCoreCall :: Mode.Mode -> Opt.Global -> [Opt.Expr] -> JS.Expr
generateCoreCall mode global@(Opt.Global home@(ModuleName.Canonical _ moduleName) name) args
  | moduleName == Name.basics  = generateBasicsCall mode home name args
  | moduleName == Name.bitwise = generateBitwiseCall home name (map (generateJsExpr mode) args)
  | moduleName == Name.tuple   = generateTupleCall   home name (map (generateJsExpr mode) args)
  | moduleName == Name.jsArray = generateJsArrayCall home name (map (generateJsExpr mode) args)
  | Just arity <- Mode.lookupArity mode global, arity == length args =
      generateDirectCall mode global args
  | otherwise                  = generateGlobalCall  home name (map (generateJsExpr mode) args)


generateTupleCall :: ModuleName.Canonical -> Name.Name -> [JS.Expr] -> JS.Expr
generateTupleCall home name args =
  case args of
    [value] ->
      case name of
        "first"  -> JS.Access value (JsName.fromLocal "a")
        "second" -> JS.Access value (JsName.fromLocal "b")
        _        -> generateGlobalCall home name args

    _ ->
      generateGlobalCall home name args


generateJsArrayCall :: ModuleName.Canonical -> Name.Name -> [JS.Expr] -> JS.Expr
generateJsArrayCall home name args =
  case args of
    [entry]        | name == "singleton" -> JS.Array [entry]
    [index, array] | name == "unsafeGet" -> JS.Index array index
    _                                    -> generateGlobalCall home name args


generateBitwiseCall :: ModuleName.Canonical -> Name.Name -> [JS.Expr] -> JS.Expr
generateBitwiseCall home name args =
  case args of
    [arg] ->
      case name of
        "complement" -> JS.Prefix JS.PrefixComplement arg
        _            -> generateGlobalCall home name args

    [left,right] ->
      case name of
        "and"            -> JS.Infix JS.OpBitwiseAnd left right
        "or"             -> JS.Infix JS.OpBitwiseOr  left right
        "xor"            -> JS.Infix JS.OpBitwiseXor left right
        "shiftLeftBy"    -> JS.Infix JS.OpLShift     right left
        "shiftRightBy"   -> JS.Infix JS.OpSpRShift   right left
        "shiftRightZfBy" -> JS.Infix JS.OpZfRShift   right left
        _                -> generateGlobalCall home name args

    _ ->
      generateGlobalCall home name args


generateBasicsCall :: Mode.Mode -> ModuleName.Canonical -> Name.Name -> [Opt.Expr] -> JS.Expr
generateBasicsCall mode home name args =
  case args of
    [elmArg] ->
      let arg = generateJsExpr mode elmArg in
      case name of
        "not"      -> JS.Prefix JS.PrefixNot arg
        "negate"   -> JS.Prefix JS.PrefixNegate arg
        "toFloat"  -> arg
        "truncate" -> JS.Infix JS.OpBitwiseOr arg (JS.Int 0)
        _          -> generateGlobalCall home name [arg]

    [elmLeft, elmRight] ->
      case name of
        -- NOTE: removed "composeL" and "composeR" because of this issue:
        -- https://github.com/elm/compiler/issues/1722
        "append"   -> append mode elmLeft elmRight
        "apL"      -> generateJsExpr mode $ apply elmLeft elmRight
        "apR"      -> generateJsExpr mode $ apply elmRight elmLeft
        _ ->
          let
            left = generateJsExpr mode elmLeft
            right = generateJsExpr mode elmRight
          in
          case name of
            "add"  -> JS.Infix JS.OpAdd left right
            "sub"  -> JS.Infix JS.OpSub left right
            "mul"  -> JS.Infix JS.OpMul left right
            "fdiv" -> JS.Infix JS.OpDiv left right
            "idiv" -> JS.Infix JS.OpBitwiseOr (JS.Infix JS.OpDiv left right) (JS.Int 0)
            "eq"   -> equal left right
            "neq"  -> notEqual left right
            "lt"   -> cmp JS.OpLt JS.OpLt   0  left right
            "gt"   -> cmp JS.OpGt JS.OpGt   0  left right
            "le"   -> cmp JS.OpLe JS.OpLt   1  left right
            "ge"   -> cmp JS.OpGe JS.OpGt (-1) left right
            "or"   -> JS.Infix JS.OpOr  left right
            "and"  -> JS.Infix JS.OpAnd left right
            "xor"  -> JS.Infix JS.OpNe  left right
            "remainderBy" -> JS.Infix JS.OpMod right left
            _      -> generateGlobalCall home name [left, right]

    _ ->
      generateGlobalCall home name (map (generateJsExpr mode) args)


equal :: JS.Expr -> JS.Expr -> JS.Expr
equal left right =
  if isLiteral left || isLiteral right then
    strictEq left right
  else
    JS.Call (JS.Ref (JsName.fromKernel Name.utils "eq")) [left, right]


notEqual :: JS.Expr -> JS.Expr -> JS.Expr
notEqual left right =
  if isLiteral left || isLiteral right then
    strictNEq left right
  else
    JS.Prefix JS.PrefixNot $
      JS.Call (JS.Ref (JsName.fromKernel Name.utils "eq")) [left, right]


cmp :: JS.InfixOp -> JS.InfixOp -> Int -> JS.Expr -> JS.Expr -> JS.Expr
cmp idealOp backupOp backupInt left right =
  if isLiteral left || isLiteral right then
    JS.Infix idealOp left right
  else
    JS.Infix backupOp
      (JS.Call (JS.Ref (JsName.fromKernel Name.utils "cmp")) [left, right])
      (JS.Int backupInt)


isLiteral :: JS.Expr -> Bool
isLiteral expr =
  case expr of
    JS.String _ -> True
    JS.Float  _ -> True
    JS.Int    _ -> True
    JS.Bool   _ -> True
    _           -> False


apply :: Opt.Expr -> Opt.Expr -> Opt.Expr
apply func value =
  case func of
    Opt.Accessor field -> Opt.Access value field
    Opt.Call f args    -> Opt.Call f (args ++ [value])
    _                  -> Opt.Call func [value]


append :: Mode.Mode -> Opt.Expr -> Opt.Expr -> JS.Expr
append mode left right =
  let seqs = generateJsExpr mode left : toSeqs mode right in
  if any isStringLiteral seqs then
    foldr1 (JS.Infix JS.OpAdd) seqs
  else
    foldr1 jsAppend seqs


jsAppend :: JS.Expr -> JS.Expr -> JS.Expr
jsAppend a b =
  JS.Call (JS.Ref (JsName.fromKernel Name.utils "ap")) [a, b]


toSeqs :: Mode.Mode -> Opt.Expr -> [JS.Expr]
toSeqs mode expr =
  case expr of
    Opt.Call (Opt.VarGlobal (Opt.Global home "append")) [left, right]
      | home == ModuleName.basics ->
          generateJsExpr mode left : toSeqs mode right

    Opt.PrimOp Opt.PrimAppend left right ->
      generateJsExpr mode left : toSeqs mode right

    _ ->
      [generateJsExpr mode expr]


isStringLiteral :: JS.Expr -> Bool
isStringLiteral expr =
  case expr of
    JS.String _ -> True
    _           -> False



-- SIMPLIFY INFIX OPERATORS


strictEq :: JS.Expr -> JS.Expr -> JS.Expr
strictEq left right =
  case left of
    JS.Int  0 -> JS.Prefix JS.PrefixNot right
    JS.Bool b -> if b then right else JS.Prefix JS.PrefixNot right
    _ ->
      case right of
        JS.Int  0 -> JS.Prefix JS.PrefixNot left
        JS.Bool b -> if b then left else JS.Prefix JS.PrefixNot left
        _         -> JS.Infix JS.OpEq left right


strictNEq :: JS.Expr -> JS.Expr -> JS.Expr
strictNEq left right =
  case left of
    JS.Int  0 -> JS.Prefix JS.PrefixNot (JS.Prefix JS.PrefixNot right)
    JS.Bool b -> if b then JS.Prefix JS.PrefixNot right else right
    _ ->
      case right of
        JS.Int  0 -> JS.Prefix JS.PrefixNot (JS.Prefix JS.PrefixNot left)
        JS.Bool b -> if b then JS.Prefix JS.PrefixNot left else left
        _         -> JS.Infix JS.OpNe left right


-- Emitted for Opt.PrimOp, i.e. when the type checker already proved both
-- operands are a JS-primitive-safe monomorphic type (see Type.Type's
-- PrimType and Optimize.Expression's toPrimBinop) — safe to use the raw JS
-- operator unconditionally, no _Utils_eq/_Utils_cmp/_Utils_ap dispatch needed.
generatePrimOp :: Mode.Mode -> Opt.PrimBinop -> Opt.Expr -> Opt.Expr -> JS.Expr
generatePrimOp mode op left right =
  case op of
    Opt.PrimEq     -> strictEq  (generateJsExpr mode left) (generateJsExpr mode right)
    Opt.PrimNeq    -> strictNEq (generateJsExpr mode left) (generateJsExpr mode right)
    Opt.PrimLt     -> JS.Infix JS.OpLt (generateJsExpr mode left) (generateJsExpr mode right)
    Opt.PrimGt     -> JS.Infix JS.OpGt (generateJsExpr mode left) (generateJsExpr mode right)
    Opt.PrimLe     -> JS.Infix JS.OpLe (generateJsExpr mode left) (generateJsExpr mode right)
    Opt.PrimGe     -> JS.Infix JS.OpGe (generateJsExpr mode left) (generateJsExpr mode right)
    Opt.PrimAppend -> foldr1 (JS.Infix JS.OpAdd) (generateJsExpr mode left : toSeqs mode right)



-- TAIL CALL


-- TODO check if JS minifiers collapse unnecessary temporary variables
--
generateTailCall :: Mode.Mode -> Name.Name -> [(Name.Name, Opt.Expr)] -> [JS.Stmt]
generateTailCall mode name args =
  let
    toTempVars (argName, arg) =
      ( JsName.makeTemp argName, generateJsExpr mode arg )

    toRealVars (argName, _) =
      JS.ExprStmt $
        JS.Assign (JS.LRef (JsName.fromLocal argName)) (JS.Ref (JsName.makeTemp argName))
  in
  JS.Vars (map toTempVars args)
  : map toRealVars args
  ++ [ JS.Continue (Just (JsName.fromLocal name)) ]



-- TAIL RECURSION MODULO CONS (Kernel List `::` only, see Optimize.Expression)


listCons :: JS.Expr
listCons =
  JS.Ref (JsName.fromKernel Name.list "Cons")


listNil :: JS.Expr
listNil =
  JS.Ref (JsName.fromKernel Name.list "Nil")


-- the accumulator's currently-open cell always has the head value at
-- field "a" (unused once filled) and the hole at field "b" (tail)
mcHoleField :: JsName.Name
mcHoleField =
  JsName.fromIndex Index.second


generateTailCallCons :: Mode.Mode -> Name.Name -> Opt.Expr -> [(Name.Name, Opt.Expr)] -> [JS.Stmt]
generateTailCallCons mode name headExpr args =
  let
    headTemp = JsName.makeMCHead name
    cellName = JsName.makeMCCell name
    endName = JsName.makeMCEnd name

    toTempVars (argName, arg) =
      ( JsName.makeTemp argName, generateJsExpr mode arg )

    toRealVars (argName, _) =
      JS.ExprStmt $
        JS.Assign (JS.LRef (JsName.fromLocal argName)) (JS.Ref (JsName.makeTemp argName))
  in
  JS.Vars ((headTemp, generateJsExpr mode headExpr) : map toTempVars args)
  : map toRealVars args
  ++
  [ JS.Var cellName (JS.Call listCons [JS.Ref headTemp, listNil])
  , JS.ExprStmt $ JS.Assign (JS.LDot (JS.Ref endName) mcHoleField) (JS.Ref cellName)
  , JS.ExprStmt $ JS.Assign (JS.LRef endName) (JS.Ref cellName)
  , JS.Continue (Just (JsName.fromLocal name))
  ]


generateTailCallConsBase :: Mode.Mode -> Name.Name -> Opt.Expr -> [JS.Stmt]
generateTailCallConsBase mode name valueExpr =
  [ JS.ExprStmt $
      JS.Assign (JS.LDot (JS.Ref (JsName.makeMCEnd name)) mcHoleField) (generateJsExpr mode valueExpr)
  , JS.Return $ JS.Access (JS.Ref (JsName.makeMCStart name)) mcHoleField
  ]



-- DEFINITIONS


-- Record the arity of a local let-bound named function so that direct
-- calls to it (in its own body, for local recursion, and in the
-- following expression) can skip A2..A9. Deliberately v1-scoped:
-- destructured function values aren't covered (arity isn't syntactically
-- visible at the binding site), and this only grows the map top-down, so
-- a forward reference to a sibling defined *later* in the same let-chain
-- still falls back to A2..A9 -- correct, just not accelerated. See
-- docs/superpowers/specs/2026-07-03-local-arity-call-bypass-design.md.
extendWithLocalArity :: Mode.Mode -> Opt.Def -> Mode.Mode
extendWithLocalArity mode def =
  case def of
    Opt.Def name (Opt.Function args _) -> Mode.addLocalArity name (length args) mode
    Opt.Def _ _                        -> mode
    Opt.TailDef name args _            -> Mode.addLocalArity name (length args) mode
    Opt.TailDefCons name args _        -> Mode.addLocalArity name (length args) mode


generateDef :: Mode.Mode -> Opt.Def -> JS.Stmt
generateDef mode def =
  case def of
    Opt.Def name body ->
      JS.Var (JsName.fromLocal name) (generateJsExpr mode body)

    Opt.TailDef name argNames body ->
      JS.Var (JsName.fromLocal name) (codeToExpr (generateTailDef mode name argNames body))

    Opt.TailDefCons name argNames body ->
      JS.Var (JsName.fromLocal name) (codeToExpr (generateTailDefCons mode name argNames body))


generateTailDef :: Mode.Mode -> Name.Name -> [Name.Name] -> Opt.Expr -> Code
generateTailDef mode name argNames body =
  generateFunction (map JsName.fromLocal argNames) $ JsBlock $
    [ JS.Labelled (JsName.fromLocal name) $
        JS.While (JS.Bool True) $
          codeToStmt $ generate mode body
    ]


generateTailDefCons :: Mode.Mode -> Name.Name -> [Name.Name] -> Opt.Expr -> Code
generateTailDefCons mode name argNames body =
  generateFunction (map JsName.fromLocal argNames) $ JsBlock $
    [ JS.Var (JsName.makeMCStart name) (JS.Call listCons [JS.Null, listNil])
    , JS.Var (JsName.makeMCEnd name) (JS.Ref (JsName.makeMCStart name))
    , JS.Labelled (JsName.fromLocal name) $
        JS.While (JS.Bool True) $
          codeToStmt $ generate mode body
    ]



-- PATHS


generatePath :: Mode.Mode -> Opt.Path -> JS.Expr
generatePath mode path =
  case path of
    Opt.Root  n   -> JS.Ref (JsName.fromLocal n)
    Opt.Index i p -> JS.Access (generatePath mode p) (JsName.fromIndex i)
    Opt.Field f p -> JS.Access (generatePath mode p) (generateField mode f)
    Opt.Unbox p ->
      case mode of
        Mode.Dev  _ -> JS.Access (generatePath mode p) (JsName.fromIndex Index.first)
        Mode.Prod _ _ -> generatePath mode p



-- GENERATE IFS


generateIf :: Mode.Mode -> [(Opt.Expr, Opt.Expr)] -> Opt.Expr -> Code
generateIf mode givenBranches givenFinal =
  let
    (branches, final) =
      crushIfs givenBranches givenFinal

    convertBranch (condition, expr) =
      ( generateJsExpr mode condition
      , generate mode expr
      )

    branchExprs = map convertBranch branches
    finalCode = generate mode final
  in
  if isBlock finalCode || any (isBlock . snd) branchExprs then
    JsBlock [ foldr addStmtIf (codeToStmt finalCode) branchExprs ]
  else
    JsExpr $ foldr addExprIf (codeToExpr finalCode) branchExprs


addExprIf :: (JS.Expr, Code) -> JS.Expr -> JS.Expr
addExprIf (condition, branch) final =
  JS.If condition (codeToExpr branch) final


addStmtIf :: (JS.Expr, Code) -> JS.Stmt -> JS.Stmt
addStmtIf (condition, branch) final =
  JS.IfStmt condition (codeToStmt branch) final


isBlock :: Code -> Bool
isBlock code =
  case code of
    JsBlock _ -> True
    JsExpr  _ -> False


crushIfs :: [(Opt.Expr, Opt.Expr)] -> Opt.Expr -> ([(Opt.Expr, Opt.Expr)], Opt.Expr)
crushIfs branches final =
  crushIfsHelp [] branches final


crushIfsHelp
    :: [(Opt.Expr, Opt.Expr)]
    -> [(Opt.Expr, Opt.Expr)]
    -> Opt.Expr
    -> ([(Opt.Expr, Opt.Expr)], Opt.Expr)
crushIfsHelp visitedBranches unvisitedBranches final =
  case unvisitedBranches of
    [] ->
        case final of
          Opt.If subBranches subFinal ->
              crushIfsHelp visitedBranches subBranches subFinal

          _ ->
              (reverse visitedBranches, final)

    visiting : unvisited ->
        crushIfsHelp (visiting : visitedBranches) unvisited final



-- CASE EXPRESSIONS


generateCase :: Mode.Mode -> Name.Name -> Name.Name -> Opt.Decider Opt.Choice -> [(Int, Opt.Expr)] -> [JS.Stmt]
generateCase mode label root decider jumps =
  foldr (goto mode label) (generateDecider mode label root decider) jumps


goto :: Mode.Mode -> Name.Name -> (Int, Opt.Expr) -> [JS.Stmt] -> [JS.Stmt]
goto mode label (index, branch) stmts =
  let
    labeledDeciderStmt =
      JS.Labelled
        (JsName.makeLabel label index)
        (JS.While (JS.Bool True) (JS.Block stmts))
  in
  labeledDeciderStmt : codeToStmtList (generate mode branch)


generateDecider :: Mode.Mode -> Name.Name -> Name.Name -> Opt.Decider Opt.Choice -> [JS.Stmt]
generateDecider mode label root decisionTree =
  case decisionTree of
    Opt.Leaf (Opt.Inline branch) ->
      codeToStmtList (generate mode branch)

    Opt.Leaf (Opt.Jump index) ->
      [ JS.Break (Just (JsName.makeLabel label index)) ]

    Opt.Chain testChain success failure ->
      [ JS.IfStmt
          (List.foldl1' (JS.Infix JS.OpAnd) (map (generateIfTest mode root) testChain))
          (JS.Block $ generateDecider mode label root success)
          (JS.Block $ generateDecider mode label root failure)
      ]

    Opt.FanOut path edges fallback ->
      [ JS.Switch
          (generateCaseTest mode root path (fst (head edges)))
          ( foldr
              (\edge cases -> generateCaseBranch mode label root edge : cases)
              [ JS.Default (generateDecider mode label root fallback) ]
              edges
          )
      ]


generateIfTest :: Mode.Mode -> Name.Name -> (DT.Path, DT.Test) -> JS.Expr
generateIfTest mode root (path, test) =
  let
    value = pathToJsExpr mode root path
  in
  case test of
    DT.IsCtor home name index _ opts ->
      let
        tag =
          case mode of
            Mode.Dev  _ -> JS.Access value JsName.dollar
            Mode.Prod _ _ ->
              case opts of
                Can.Normal -> JS.Access value JsName.dollar
                Can.Enum   -> value
                Can.Unbox  -> value
      in
      strictEq tag $
        case mode of
          Mode.Dev _ -> JS.String (Name.toBuilder name)
          Mode.Prod _ _ -> JS.Int (ctorToInt home name index)

    DT.IsBool True  -> value
    DT.IsBool False -> JS.Prefix JS.PrefixNot value
    DT.IsInt i      -> strictEq value (JS.Int i)

    DT.IsChr char ->
      strictEq (JS.String (P.primBounded charUtf8 char)) $
        case mode of
          Mode.Dev _ -> JS.Call (JS.Access value (JsName.fromLocal "valueOf")) []
          Mode.Prod _ _ -> value

    DT.IsStr string ->
      strictEq value (JS.String (Utf8.toBuilder string))

    DT.IsCons ->
      JS.Access value (JsName.fromLocal "b")

    DT.IsNil ->
      JS.Prefix JS.PrefixNot $
        JS.Access value (JsName.fromLocal "b")

    DT.IsTuple ->
      error "COMPILER BUG - there should never be tests on a tuple"



generateCaseBranch :: Mode.Mode -> Name.Name -> Name.Name -> (DT.Test, Opt.Decider Opt.Choice) -> JS.Case
generateCaseBranch mode label root (test, subTree) =
  JS.Case
    (generateCaseValue mode test)
    (generateDecider mode label root subTree)


generateCaseValue :: Mode.Mode -> DT.Test -> JS.Expr
generateCaseValue mode test =
  case test of
    DT.IsCtor home name index _ _ ->
      case mode of
        Mode.Dev  _ -> JS.String (Name.toBuilder name)
        Mode.Prod _ _ -> JS.Int (ctorToInt home name index)

    DT.IsInt  i -> JS.Int i
    DT.IsChr  c -> JS.String (P.primBounded charUtf8 c)
    DT.IsStr  s -> JS.String (Utf8.toBuilder s)
    DT.IsBool _ -> error "COMPILER BUG - there should never be three tests on a boolean"
    DT.IsCons   -> error "COMPILER BUG - there should never be three tests on a list"
    DT.IsNil    -> error "COMPILER BUG - there should never be three tests on a list"
    DT.IsTuple  -> error "COMPILER BUG - there should never be three tests on a tuple"


generateCaseTest :: Mode.Mode -> Name.Name -> DT.Path -> DT.Test -> JS.Expr
generateCaseTest mode root path exampleTest =
  let
    value = pathToJsExpr mode root path
  in
  case exampleTest of
    DT.IsCtor home name _ _ opts ->
      if name == Name.bool && home == ModuleName.basics then
        value
      else
        case mode of
          Mode.Dev  _ -> JS.Access value JsName.dollar
          Mode.Prod _ _ ->
            case opts of
              Can.Normal -> JS.Access value JsName.dollar
              Can.Enum   -> value
              Can.Unbox  -> value

    DT.IsInt _ -> value
    DT.IsStr _ -> value
    DT.IsChr _ ->
      case mode of
        Mode.Dev  _ -> JS.Call (JS.Access value (JsName.fromLocal "valueOf")) []
        Mode.Prod _ _ -> value

    DT.IsBool _ -> error "COMPILER BUG - there should never be three tests on a list"
    DT.IsCons   -> error "COMPILER BUG - there should never be three tests on a list"
    DT.IsNil    -> error "COMPILER BUG - there should never be three tests on a list"
    DT.IsTuple  -> error "COMPILER BUG - there should never be three tests on a list"



-- PATTERN PATHS


pathToJsExpr :: Mode.Mode -> Name.Name -> DT.Path -> JS.Expr
pathToJsExpr mode root path =
  case path of
    DT.Index i p ->
      JS.Access (pathToJsExpr mode root p) (JsName.fromIndex i)

    DT.Unbox p ->
      case mode of
        Mode.Dev  _ -> JS.Access (pathToJsExpr mode root p) (JsName.fromIndex Index.first)
        Mode.Prod _ _ -> pathToJsExpr mode root p

    DT.Empty ->
      JS.Ref (JsName.fromLocal root)



-- GENERATE CHAR


charUtf8 :: P.BoundedPrim Char
charUtf8 =
    P.condB (== '\\') (esc 0x5C) $
    P.condB (== '\'') (esc 0x27) $
    P.condB (>= ' ' ) P.charUtf8 $
    P.condB (== '\b') (esc 0x62) $
    P.condB (== '\f') (esc 0x66) $
    P.condB (== '\n') (esc 0x6E) $
    P.condB (== '\r') (esc 0x72) $
    P.condB (== '\t') (esc 0x74) $ fallback
  where
    {-# INLINE esc #-}
    esc w =
      P.liftFixedToBounded $ const (0x5C,w) >$< P.word8 >*< P.word8

    {-# INLINE fallback #-}
    fallback =
      P.liftFixedToBounded $ (\c -> (0x5C,(0x75,(0x30,(0x30,toFallback c))))) >$<
        P.word8 >*< P.word8 >*< P.word8 >*< P.word8 >*< P.word8 >*< P.word8

    toFallback char =
        if w < 0x10
        then (0x30, if w < 0x0a then w + 0x30 else w + 0x57)
        else (0x31, if w < 0x1a then w + 0x20 else w + 0x47)
      where
        w = fromIntegral (Char.ord char)



-- GENERATE MAIN


generateMain :: Mode.Mode -> ModuleName.Canonical -> Opt.Main -> JS.Expr
generateMain mode home main =
  case main of
    Opt.Static ->
      JS.Ref (JsName.fromKernel Name.virtualDom "init")
        # JS.Ref (JsName.fromGlobal home "main")
        # JS.Int 0
        # JS.Int 0

    Opt.Dynamic msgType decoder ->
      JS.Ref (JsName.fromGlobal home "main")
        # generateJsExpr mode decoder
        # toDebugMetadata mode msgType


(#) :: JS.Expr -> JS.Expr -> JS.Expr
(#) func arg =
  JS.Call func [arg]


toDebugMetadata :: Mode.Mode -> Can.Type -> JS.Expr
toDebugMetadata mode msgType =
  case mode of
    Mode.Prod _ _ ->
      JS.Int 0

    Mode.Dev Nothing ->
      JS.Int 0

    Mode.Dev (Just interfaces) ->
      JS.Json $ Encode.object $
        [ "versions" ==> Encode.object [ "elm" ==> V.encode V.compiler ]
        , "types"    ==> Type.encodeMetadata (Extract.fromMsg interfaces msgType)
        ]
