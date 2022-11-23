module Keelung.Compiler.Syntax.Erase (run) where

import Control.Monad.State
import Data.Field.Galois (GaloisField)
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq (..), (|>))
import Keelung.Compiler.Syntax.FieldBits (FieldBits (..))
import Keelung.Compiler.Syntax.Untyped
import qualified Keelung.Syntax.BinRep as BinRep
import qualified Keelung.Syntax.Typed as T
import Keelung.Syntax.VarCounters

run :: (GaloisField n, Integral n) => T.Elaborated -> TypeErased n
run (T.Elaborated expr comp) =
  let T.Computation counters numAsgns boolAsgns _ assertions = comp
      proxy = 0
   in runM counters $ do
        -- update VarCounters.varNumWidth before type erasure
        let numBitWidth = bitSize proxy
        let counters' = setNumBitWidth numBitWidth $ setOutputVarSize (lengthOfExpr expr) counters
        put counters'
        -- start type erasure
        expr' <- map snd <$> eraseExpr expr
        sameType proxy expr'
        numAssignments' <- mapM eraseAssignment numAsgns
        boolAssignments' <- mapM eraseAssignment boolAsgns
        let assignments = numAssignments' <> boolAssignments'
        assertions' <- map snd . concat <$> mapM eraseExpr assertions

        -- retrieve updated Context and return it
        counters'' <- get

        -- associate input variables with their corresponding binary representation
        let numBinReps =
              let (start, end) = numInputVarsRange counters''
               in BinRep.fromList $
                    map
                      (\v -> BinRep.fromNumBinRep numBitWidth (v, fromMaybe (error ("Panic: cannot query bits of var $" <> show v)) (lookupBinRepStart counters'' v)))
                      [start .. end - 1]

        let customBinReps =
              BinRep.fromList $
                concatMap
                  ( \(width, (start, end)) ->
                      map
                        (\v -> BinRep.fromNumBinRep width (v, fromMaybe (error ("Panic: cannot query bits of var $" <> show v)) (lookupBinRepStart counters'' v)))
                        [start .. end - 1]
                  )
                  (IntMap.toList (customInputVarsRanges counters''))

        return $
          TypeErased
            { erasedExpr = expr',
              -- determine the size of output vars by looking at the length of the expression
              erasedVarCounters = counters'',
              erasedRelations = mempty,
              erasedAssertions = assertions',
              erasedAssignments = assignments,
              erasedBinReps = numBinReps,
              erasedCustomBinReps = customBinReps
            }
  where
    -- proxy trick for devising the bit width of field elements
    sameType :: n -> [Expr n] -> M n ()
    sameType _ _ = return ()

    lengthOfExpr :: T.Expr -> Int
    lengthOfExpr (T.Array xs) = sum $ fmap lengthOfExpr xs
    lengthOfExpr (T.Val T.Unit) = 0
    lengthOfExpr _ = 1

--------------------------------------------------------------------------------

-- monad for collecting boolean vars along the way
type M n = State VarCounters

runM :: VarCounters -> M n a -> a
runM = flip evalState

--------------------------------------------------------------------------------

eraseVal :: GaloisField n => T.Val -> M n [(BitWidth, Expr n)]
eraseVal (T.Integer n) = do
  width <- gets getNumBitWidth
  return [(BWNumber width, ExprN $ ValN width (fromInteger n))]
eraseVal (T.Rational n) = do
  width <- gets getNumBitWidth
  return [(BWNumber width, ExprN $ ValN width (fromRational n))]
eraseVal (T.Unsigned width n) =
  return [(BWUInt width, ExprU $ ValU width (fromIntegral n))]
eraseVal (T.Boolean False) =
  return [(BWBoolean, ExprB $ ValB 0)]
eraseVal (T.Boolean True) =
  return [(BWBoolean, ExprB $ ValB 1)]
eraseVal T.Unit = return []

-- eraseValN :: GaloisField n => T.Val -> M n [(BitWidth, ExprN n)]
-- eraseValN (T.Integer n) = do
--   width <- gets getNumBitWidth
--   return [(BWNumber width, ValN width (fromInteger n))]
-- eraseValN (T.Rational n) = do
--   width <- gets getNumBitWidth
--   return [(BWNumber width, ValN width (fromRational n))]
-- eraseValN (T.Unsigned _ _) =
--   error "[ panic ] eraseValN on UInt"
-- eraseValN (T.Boolean _) =
--   error "[ panic ] eraseValN on Boolean"
-- eraseValN T.Unit = error "[ panic ] eraseValN on Unit"

-- eraseValU :: GaloisField n => T.Val -> M n [(BitWidth, ExprU n)]
-- eraseValU (T.Integer _) =
--   error "[ panic ] eraseValU on Integer"
-- eraseValU (T.Rational _) =
--   error "[ panic ] eraseValU on Rational"
-- eraseValU (T.Unsigned width n) =
--   return [(BWUInt width, ValU width (fromIntegral n))]
-- eraseValU (T.Boolean _) =
--   error "[ panic ] eraseValU on Boolean"
-- eraseValU T.Unit = error "[ panic ] eraseValU on Unit"

-- Current layout of variables
--
-- ┏━━━━━━━━━━━━━━━━━┓
-- ┃         Output  ┃
-- ┣─────────────────┫
-- ┃   Number Input  ┃
-- ┣─────────────────┫
-- ┃   Custom Input  ┃
-- ┣─────────────────┫─ ─ ─ ─ ─ ─ ─ ─
-- ┃  Boolean Input  ┃               │
-- ┣─────────────────┫
-- ┃  Binary Rep of  ┃
-- ┃   Number Input  ┃   Contiguous chunk of bits
-- ┣─────────────────┫
-- ┃  Binary Rep of  ┃
-- ┃   Custom Input  ┃               │
-- ┣─────────────────┫─ ─ ─ ─ ─ ─ ─ ─
-- ┃   Intermediate  ┃
-- ┗━━━━━━━━━━━━━━━━━┛
--
eraseRef3 :: T.Ref -> M n (BitWidth, Expr n)
eraseRef3 ref = do
  counters <- get
  let numWidth = getNumBitWidth counters
  return $ case ref of
    T.VarN n -> (BWNumber numWidth, ExprN $ VarN numWidth $ blendIntermediateVar counters n)
    T.InputVarN n -> (BWNumber numWidth, ExprN $ VarN numWidth $ blendInputVarN counters n)
    T.VarB n -> (BWBoolean, ExprB $ VarB $ blendIntermediateVar counters n)
    T.InputVarB n -> (BWBoolean, ExprB $ VarB $ blendInputVarB counters n)
    T.VarU w n -> (BWUInt w, ExprU $ VarU w $ blendIntermediateVar counters n)
    T.InputVarU w n -> (BWUInt w, ExprU $ VarU w $ blendInputVarU counters w n)

-- eraseRefN :: T.Ref -> M n (BitWidth, ExprN n)
-- eraseRefN ref = do
--   counters <- get
--   let numWidth = getNumBitWidth counters
--   return $ case ref of
--     T.VarN n -> (BWNumber numWidth, VarN numWidth $ blendIntermediateVar counters n)
--     T.InputVarN n -> (BWNumber numWidth,  VarN numWidth $ blendInputVarN counters n)
--     T.VarB _ -> error "[ panic ] eraseRefN on BoolVar"
--     T.InputVarB _ -> error "[ panic ] eraseRefN on InputVarB"
--     T.VarU _ _ -> error "[ panic ] eraseRefN on VarU"
--     T.InputVarU _ _ -> error "[ panic ] eraseRefN on InputVarU"

-- eraseRefU :: T.Ref -> M n (BitWidth, ExprU n)
-- eraseRefU ref = do
--   counters <- get
--   return $ case ref of
--     T.VarN _ -> error "[ panic ] eraseRefU on NumVar"
--     T.InputVarN _ -> error "[ panic ] eraseRefU on InputVarN"
--     T.VarB _ -> error "[ panic ] eraseRefU on BoolVar"
--     T.InputVarB _ -> error "[ panic ] eraseRefU on InputVarB"
--     T.VarU w n -> (BWUInt w, VarU w $ blendIntermediateVar counters n)
--     T.InputVarU w n -> (BWUInt w, VarU w $ blendInputVarU counters w n)

eraseRef2 :: T.Ref -> M n Int
eraseRef2 ref = do
  counters <- get
  return $ case ref of
    T.VarN n -> blendIntermediateVar counters n
    T.InputVarN n -> blendInputVarN counters n
    T.VarB n -> blendIntermediateVar counters n
    T.InputVarB n -> blendInputVarB counters n
    T.VarU _ n -> blendIntermediateVar counters n
    T.InputVarU w n -> blendInputVarU counters w n

-- eraseRef :: GaloisField n => T.Ref -> M n (Expr n)
-- eraseRef ref = do
--   counters <- get
--   let numWidth = getNumBitWidth counters
--   return $ case ref of
--     T.VarN n -> VarN numWidth $ blendIntermediateVar counters n
--     T.InputVarN n -> VarN numWidth $ blendInputVarN counters n
--     T.VarB n -> VarB $ blendIntermediateVar counters n
--     T.InputVarB n -> VarB $ blendInputVarB counters n
--     T.VarU w n -> VarU w $ blendIntermediateVar counters n
--     T.InputVarU w n -> VarU w $ blendInputVarU counters w n

-- eraseExprN :: (GaloisField n, Integral n) => T.Expr -> M n [(BitWidth, ExprN n)]
-- eraseExprN expr = case expr of
--   T.Val val -> eraseValN val
--   T.Var ref -> pure <$> eraseRefN ref
--   T.Array exprs -> do
--     exprss <- mapM eraseExprN exprs
--     return (concat exprss)
--   T.Add x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     let (bw, x') = head xs
--     case bw of
--       BWNumber _ -> return [ second narrowDownToExprN (chainExprsOfAssocOp AddN (bw, x') (head ys))]
--       BWUInt _ -> return [ second narrowDownToExprN (chainExprsOfAssocOp AddU (bw, x') (head ys))]
--       _ -> error "[ panic ] T.Add on wrong type of data"
--   T.Sub x y -> do
--     xs <- eraseExprN x
--     ys <- eraseExprN y
--     let (bw, x') = head xs
--     let (_, y') = head ys
--     case bw of
--       BWNumber _ -> return [(bw, SubN bw x' y')]
--       _ -> error "[ panic ] T.Sub on wrong type of data"
--   T.Mul x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Mul (head xs) (head ys))]
--   T.Div x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     let (bw, x') = head xs
--     let (_, y') = head ys
--     return [(bw, narrowDownToExprN (Div bw x' y'))]
--   T.Eq x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Eq (head xs) (head ys))]
--   T.And x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp And (head xs) (head ys))]
--   T.Or x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Or (head xs) (head ys))]
--   T.Xor x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Xor (head xs) (head ys))]
--   T.RotateR n x -> do
--     xs <- eraseExpr x
--     let (bw, x') = head xs
--     return [(bw, narrowDownToExprN (Rotate bw n x'))]
--   T.BEq x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp BEq (head xs) (head ys))]
--   T.If b x y -> do
--     bs <- eraseExpr b
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     let (bw, x') = head xs
--     return [(bw, narrowDownToExprN (If bw (snd (head bs)) x' (snd (head ys))))]
--   T.ToNum x -> do
--     counters <- get
--     let numWidth = getNumBitWidth counters
--     fmap (\(_, e) -> (BWNumber numWidth, narrowDownToExprN e)) <$> eraseExpr x
--   T.Bit x i -> do
--     (_, x') <- head <$> eraseExpr x
--     value <- bitValue x' i
--     return [(BWBoolean, narrowDownToExprN value)]

-- eraseExprB :: (GaloisField n, Integral n) => T.Expr -> M n [ExprB n]
-- eraseExprB expr = case expr of
--   T.Val val -> eraseValB val
--   T.Var ref -> pure <$> eraseRefN ref
--   T.Array exprs -> do
--     exprss <- mapM eraseExprN exprs
--     return (concat exprss)
--   T.Add x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     let (bw, x') = head xs
--     case bw of
--       BWNumber _ -> return [ second narrowDownToExprN (chainExprsOfAssocOp AddN (bw, x') (head ys))]
--       BWUInt _ -> return [ second narrowDownToExprN (chainExprsOfAssocOp AddU (bw, x') (head ys))]
--       _ -> error "[ panic ] T.Add on wrong type of data"
--   T.Sub x y -> do
--     xs <- eraseExprN x
--     ys <- eraseExprN y
--     let (bw, x') = head xs
--     let (_, y') = head ys
--     case bw of
--       BWNumber _ -> return [(bw, SubN bw x' y')]
--       _ -> error "[ panic ] T.Sub on wrong type of data"
--   T.Mul x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Mul (head xs) (head ys))]
--   T.Div x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     let (bw, x') = head xs
--     let (_, y') = head ys
--     return [(bw, narrowDownToExprN (Div bw x' y'))]
--   T.Eq x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Eq (head xs) (head ys))]
--   T.And x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp And (head xs) (head ys))]
--   T.Or x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Or (head xs) (head ys))]
--   T.Xor x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp Xor (head xs) (head ys))]
--   T.RotateR n x -> do
--     xs <- eraseExpr x
--     let (bw, x') = head xs
--     return [(bw, narrowDownToExprN (Rotate bw n x'))]
--   T.BEq x y -> do
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     return [second narrowDownToExprN (chainExprsOfAssocOp BEq (head xs) (head ys))]
--   T.If b x y -> do
--     bs <- eraseExpr b
--     xs <- eraseExpr x
--     ys <- eraseExpr y
--     let (bw, x') = head xs
--     return [(bw, narrowDownToExprN (If bw (snd (head bs)) x' (snd (head ys))))]
--   T.ToNum x -> do
--     counters <- get
--     let numWidth = getNumBitWidth counters
--     fmap (\(_, e) -> (BWNumber numWidth, narrowDownToExprN e)) <$> eraseExpr x
--   T.Bit x i -> do
--     (_, x') <- head <$> eraseExpr x
--     value <- bitValue x' i
--     return [(BWBoolean, narrowDownToExprN value)]

eraseExpr :: (GaloisField n, Integral n) => T.Expr -> M n [(BitWidth, Expr n)]
eraseExpr expr = case expr of
  T.Val val -> eraseVal val
  T.Var ref -> pure <$> eraseRef3 ref
  T.Array exprs -> do
    exprss <- mapM eraseExpr exprs
    return (concat exprss)
  T.Add x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWNumber w -> return [(bw, ExprN $ chainExprsOfAssocOpAddN w (narrowDownToExprN x') (narrowDownToExprN y'))]
      BWUInt w -> return [(bw, ExprU $ AddU w (narrowDownToExprU x') (narrowDownToExprU y'))]
      _ -> error "[ panic ] T.Add on wrong type of data"
  T.Sub x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWNumber w -> return [(bw, ExprN $ SubN w (narrowDownToExprN x') (narrowDownToExprN y'))]
      BWUInt w -> return [(bw, ExprU $ SubU w (narrowDownToExprU x') (narrowDownToExprU y'))]
      _ -> error "[ panic ] T.Sub on wrong type of data"
  T.Mul x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWNumber w -> return [(bw, ExprN $ MulN w (narrowDownToExprN x') (narrowDownToExprN y'))]
      BWUInt w -> return [(bw, ExprU $ MulU w (narrowDownToExprU x') (narrowDownToExprU y'))]
      _ -> error "[ panic ] T.Mul on wrong type of data"
  T.Div x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    return [(bw, ExprN $ DivN (getWidth bw) (narrowDownToExprN x') (narrowDownToExprN y'))]
  T.Eq x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWNumber _ -> return [(bw, ExprB $ EqN (narrowDownToExprN x') (narrowDownToExprN y'))]
      BWUInt _ -> return [(bw, ExprB $ EqU (narrowDownToExprU x') (narrowDownToExprU y'))]
      BWBoolean -> return [(bw, ExprB $ EqB (narrowDownToExprB x') (narrowDownToExprB y'))]
      _ -> error "[ panic ] T.Eq on wrong type of data"
  T.And x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWBoolean -> return [(bw, ExprB $ chainExprsOfAssocOpAndB (narrowDownToExprB x') (narrowDownToExprB y'))]
      BWUInt w -> return [(bw, ExprU $ chainExprsOfAssocOpAndU w (narrowDownToExprU x') (narrowDownToExprU y'))]
      _ -> error "[ panic ] T.And on wrong type of data"
  T.Or x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWBoolean -> return [(bw, ExprB $ chainExprsOfAssocOpOrB (narrowDownToExprB x') (narrowDownToExprB y'))]
      BWUInt w -> return [(bw, ExprU $ chainExprsOfAssocOpOrU w (narrowDownToExprU x') (narrowDownToExprU y'))]
      _ -> error "[ panic ] T.Or on wrong type of data"
  T.Xor x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWBoolean -> return [(bw, ExprB $ XorB (narrowDownToExprB x') (narrowDownToExprB y'))]
      BWUInt w -> return [(bw, ExprU $ XorU w (narrowDownToExprU x') (narrowDownToExprU y'))]
      _ -> error "[ panic ] T.XOr on wrong type of data"
  T.RotateR n x -> do
    xs <- eraseExpr x
    let (bw, x') = head xs
    return [(bw, Rotate bw n x')]
  T.BEq x y -> do
    xs <- eraseExpr x
    ys <- eraseExpr y
    let (bw, x') = head xs
    let (_, y') = head ys
    case bw of
      BWBoolean -> return [(bw, ExprB $ EqB (narrowDownToExprB x') (narrowDownToExprB y'))]
      BWUInt _ -> return [(bw, ExprB $ EqU (narrowDownToExprU x') (narrowDownToExprU y'))]
      BWNumber _ -> return [(bw, ExprB $ EqN (narrowDownToExprN x') (narrowDownToExprN y'))]
      _ -> error "[ panic ] T.XOr on wrong type of data"
  T.If p x y -> do
    (_, p') <- head <$> eraseExpr p
    (bw, x') <- head <$> eraseExpr x
    (_, y') <- head <$> eraseExpr y
    case bw of
      BWBoolean -> return [(bw, ExprB $ IfB (narrowDownToExprB p') (narrowDownToExprB x') (narrowDownToExprB y'))]
      BWNumber w -> return [(bw, ExprN $ IfN w (narrowDownToExprB p') (narrowDownToExprN x') (narrowDownToExprN y'))]
      BWUInt w -> return [(bw, ExprU $ IfU w (narrowDownToExprB p') (narrowDownToExprU x') (narrowDownToExprU y'))]
      _ -> error "[ panic ] T.If on wrong type of data"
  T.ToNum x -> do
    counters <- get
    let numWidth = getNumBitWidth counters
    fmap (\(_, e) -> (BWNumber numWidth, castToNumber numWidth e)) <$> eraseExpr x
  T.Bit x i -> do
    (_, x') <- head <$> eraseExpr x
    value <- bitValue x' i
    return [(BWBoolean, ExprB value)]
  T.NotU x -> do
    (bw, x') <- head <$> eraseExpr x
    case bw of
      BWUInt w -> return [(bw, ExprU $ NotU w (narrowDownToExprU x'))]
      _ -> error "[ panic ] T.NotU on wrong type of data"

bitValue :: (Integral n, GaloisField n) => Expr n -> Int -> M n (ExprB n)
bitValue expr i = case expr of
  ExprN (ValN _ n) -> return (ValB (testBit n i))
  ExprN (VarN w var) -> do
    counters <- get
    -- if the index 'i' overflows or underflows, wrap it around
    let i' = i `mod` w
    -- bit variable corresponding to the variable 'var' and the index 'i''
    case lookupBinRepStart counters var of
      Nothing -> error $ "Panic: unable to get perform bit test on $" <> show var <> "[" <> show i' <> "]"
      Just start -> return $ VarB (start + i')
  ExprN _ -> error "Panic: trying to access the bit value of a compound expression"
  ExprU (ValU _ n) -> return (ValB (testBit n i))
  ExprU (VarU w var) -> do
    counters <- get
    -- if the index 'i' overflows or underflows, wrap it around
    let i' = i `mod` w
    -- bit variable corresponding to the variable 'var' and the index 'i''
    case lookupBinRepStart counters var of
      Nothing -> error $ "Panic: unable to get perform bit test on $" <> show var <> "[" <> show i' <> "]"
      Just start -> return $ VarB (start + i')
  ExprU (AndU _ x y rest) ->
    AndB
      <$> bitValue (ExprU x) i
      <*> bitValue (ExprU y) i
      <*> mapM (\x' -> ExprU x' `bitValue` i) rest
  ExprU (OrU _ x y rest) ->
    OrB
      <$> bitValue (ExprU x) i
      <*> bitValue (ExprU y) i
      <*> mapM (\x' -> ExprU x' `bitValue` i) rest
  ExprU (XorU _ x y) ->
    XorB
      <$> bitValue (ExprU x) i
      <*> bitValue (ExprU y) i
  ExprU _ -> error "Panic: trying to access the bit value of a compound expression"
  ExprB x -> return x
  Rotate w n x -> do
    -- rotate the bit value
    -- if the index 'i' overflows or underflows, wrap it around
    let i' = n + i `mod` getWidth w
    bitValue x i'

eraseAssignment :: (GaloisField n, Integral n) => T.Assignment -> M n (Assignment n)
eraseAssignment (T.Assignment ref expr) = do
  var <- eraseRef2 ref
  exprs <- eraseExpr expr
  return $ Assignment var (snd (head exprs))

-- | Flatten and chain expressions with associative operator together when possible
chainExprsOfAssocOpAddN :: Width -> ExprN n -> ExprN n -> ExprN n
chainExprsOfAssocOpAddN w x y = case (x, y) of
  (AddN _ x0 x1 xs, AddN _ y0 y1 ys) ->
    AddN w x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (AddN _ x0 x1 xs, _) ->
    AddN w x0 x1 (xs |> y)
  (_, AddN _ y0 y1 ys) ->
    AddN w x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> AddN w x y mempty

chainExprsOfAssocOpAndB :: ExprB n -> ExprB n -> ExprB n
chainExprsOfAssocOpAndB x y = case (x, y) of
  (AndB x0 x1 xs, AndB y0 y1 ys) ->
    AndB x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (AndB x0 x1 xs, _) ->
    AndB x0 x1 (xs |> y)
  (_, AndB y0 y1 ys) ->
    AndB x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> AndB x y mempty

chainExprsOfAssocOpAndU :: Width -> ExprU n -> ExprU n -> ExprU n
chainExprsOfAssocOpAndU w x y = case (x, y) of
  (AndU _ x0 x1 xs, AndU _ y0 y1 ys) ->
    AndU w x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (AndU _ x0 x1 xs, _) ->
    AndU w x0 x1 (xs |> y)
  (_, AndU _ y0 y1 ys) ->
    AndU w x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> AndU w x y mempty

chainExprsOfAssocOpOrB :: ExprB n -> ExprB n -> ExprB n
chainExprsOfAssocOpOrB x y = case (x, y) of
  (OrB x0 x1 xs, OrB y0 y1 ys) ->
    OrB x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (OrB x0 x1 xs, _) ->
    OrB x0 x1 (xs |> y)
  (_, OrB y0 y1 ys) ->
    OrB x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> OrB x y mempty

chainExprsOfAssocOpOrU :: Width -> ExprU n -> ExprU n -> ExprU n
chainExprsOfAssocOpOrU w x y = case (x, y) of
  (OrU _ x0 x1 xs, OrU _ y0 y1 ys) ->
    OrU w x0 x1 (xs <> (y0 :<| y1 :<| ys))
  (OrU _ x0 x1 xs, _) ->
    OrU w x0 x1 (xs |> y)
  (_, OrU _ y0 y1 ys) ->
    OrU w x y0 (y1 :<| ys)
  -- there's nothing left we can do
  _ -> OrU w x y mempty